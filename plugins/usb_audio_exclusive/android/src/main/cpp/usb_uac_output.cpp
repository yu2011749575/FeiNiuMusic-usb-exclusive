// usb_uac_output.cpp —— 用户态 USB Audio Class 1/2 输出驱动（bit-perfect）。
//
// 设计（自研实现，技术路线参考开源项目 decent-player 的公开文档）：
//   * 不经 AudioFlinger / AudioTrack / AAudio / ALSA / 内核 snd-usb-audio。
//     通过 Linux usbdevfs 的等时传输（USBDEVFS_SUBMITURB + USBDEVFS_URB_ISO_ASAP）
//     把解码出的 PCM 位原样写给 USB DAC —— DAC 收到的位即解码出的位。
//   * 必须在 Java 层用 UsbDeviceConnection.setInterface() 选择 alt setting
//     （xHCI 只有这样才会为等时端点预留带宽；native 的 USBDEVFS_SETINTERFACE
//     不分配带宽，会静默丢包 —— decent-player 踩坑记录之一）。
//   * URB 管线深度 80 个（每 URB 8 个 ISO 包）：太短会在部分 SoC 上静音。
//   * 44.1k 等非整数采样率用小数累加器规划每包采样数（永远慢 0.2% 会累积漂移）。
//   * 全程整数位移搬运（16→24/32 左移补零为精确升位），不做 float 混音/重采样。
//
// JNI 类：com.feiniu.usb_audio_exclusive.NativeUac

#include <jni.h>
#include <android/log.h>

#include <linux/usbdevice_fs.h>
#include <linux/usb/ch9.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <cerrno>
#include <cmath>
#include <string>
#include <vector>
#include <atomic>

#define LOG_TAG "UsbUacOutput"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#ifndef USBDEVFS_REAPURB
#define USBDEVFS_REAPURB _IOR('U', 12, void *)
#endif
#ifndef USBDEVFS_REAPURBNDELAY
#define USBDEVFS_REAPURBNDELAY _IOR('U', 13, void *)
#endif
#ifndef USBDEVFS_CLAIMINTERFACE
#define USBDEVFS_CLAIMINTERFACE _IOR('U', 15, unsigned int)
#endif

// ---------------------------------------------------------------------------
// UAC 常量（USB Audio Class 1/2 规范）
// ---------------------------------------------------------------------------
// 注意：<linux/usb/ch9.h> 已把 USB_DT_CS_* 定义为宏，先解除再用常量。
#undef USB_DT_CS_INTERFACE
#undef USB_DT_CS_ENDPOINT
static const uint8_t USB_DT_CS_INTERFACE = 0x24;
static const uint8_t USB_DT_CS_ENDPOINT = 0x25;

// UAC2 CS_INTERFACE 子类型
static const uint8_t UAC2_CLOCK_SOURCE = 0x0A;
static const uint8_t UAC2_FEATURE_UNIT = 0x06;
// UAC1/UAC2 通用：AS_GENERAL=0x01, FORMAT_TYPE=0x02
static const uint8_t CS_AS_GENERAL = 0x01;
static const uint8_t CS_FORMAT_TYPE = 0x02;
static const uint8_t CS_EP_GENERAL = 0x01;

// 控制请求
static const uint8_t SET_CUR = 0x01;
static const uint8_t GET_CUR = 0x81;
static const uint8_t SAMPLING_FREQ_CONTROL = 0x01;
static const uint8_t PITCH_CONTROL = 0x02;

static const int NUM_URBS = 80;        // URB 管线深度（decent-player：太短会静音）
static const int PACKETS_PER_URB = 8;  // HS=8 个 125us 微帧；FS=8 个 1ms 帧

// 输入 PCM 编码（对应 android.media.AudioFormat 的 ENCODING_*）
static const int ENC_PCM_16 = 2;
static const int ENC_PCM_FLOAT = 4;
static const int ENC_PCM_24_PACKED = 21;
static const int ENC_PCM_32 = 22;

// ---------------------------------------------------------------------------
// 描述符解析结果
// ---------------------------------------------------------------------------
struct AltSetting {
    int iface = 0;          // 接口号（bInterfaceNumber）
    int alt = 0;            // 备用设置（bAlternateSetting）
    int epAddr = 0;         // 等时 OUT 端点地址（含方向位）
    int maxPacket = 0;      // wMaxPacketSize（每包最大字节）
    int syncType = 0;       // USB_ENDPOINT_SYNC_*（1=async 2=adaptive 3=sync）
    int fbEpAddr = 0;       // 显式反馈端点（IN），0=无
    int channels = 0;
    int subframe = 0;       // bSubframeSize：每采样字节数（2/3/4）
    int bitDepth = 0;       // bBitResolution（16/24/32）
    std::vector<int> rates; // 离散采样率列表
    int rateMin = 0, rateMax = 0; // 连续范围（rates 为空时有效）
    bool supportsRate(int r) const {
        if (!rates.empty()) {
            for (int x : rates) if (x == r) return true;
            return false;
        }
        if (rateMin == 0 && rateMax == 0) return true; // 无静态率表（UAC2 时钟编程型）
        return r >= rateMin && r <= rateMax;
    }
};

struct DeviceInfo {
    bool uac2 = false;
    bool highSpeed = false;
    int acIface = 0;        // AudioControl 接口号
    int clockId = 0;        // UAC2 Clock Source Entity ID（UAC1=0）
    int fuId = 0;           // Feature Unit Entity ID（0=未找到，无静音/音量控件）
    std::vector<AltSetting> alts;
};

// ---------------------------------------------------------------------------
// 输出上下文
// ---------------------------------------------------------------------------
struct UacOutput {
    int fd = -1;            // usbdevfs fd（dup 自 Java UsbDeviceConnection）
    AltSetting alt;
    bool uac2 = false;
    bool highSpeed = false;
    int acIface = 0;
    int clockId = 0;

    // 输入/输出 PCM 格式
    int inEnc = ENC_PCM_16; // MediaCodec 输出编码
    int inFrame = 2;        // 输入每帧字节数（channels*每采样字节）
    int sampleRate = 44100; // 源采样率（解码侧）
    int wireRate = 44100;   // 线上采样率（DAC 协商结果；≠sampleRate 时重采样）
    int srcBits = 16;       // 源位深（dither 降位判定用）
    int channels = 2;
    int wireFrame = 0;      // 输出每帧字节数 = channels*subframe

    // 重采样状态（sampleRate≠wireRate 时启用；线性插值，跨调用保持相位）
    std::vector<int32_t> rsPrev; // 上一输入帧（outCh 声道，int32 刻度）
    double rsFrac = 0.0;         // 当前输出帧在输入流中的小数相位

    // TPDF dither 随机源（仅 DAC 位深低于源位深时使用）
    uint32_t ditherSeed = 0x2545F491;

    // PCM 环形缓冲（输入编码格式，write 线程写入 / reaper 线程消费）
    std::vector<uint8_t> ring;
    size_t ringCap = 0;
    std::atomic<size_t> ringR{0};
    std::atomic<size_t> ringW{0};
    pthread_mutex_t ringMu = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t ringCond = PTHREAD_COND_INITIALIZER; // 空间/数据可用

    // URB 管线
    std::vector<usbdevfs_urb *> urbs;
    std::vector<std::vector<uint8_t>> urbBuf;

    // 采样规划（小数累加器）
    std::atomic<long long> rateMilli{0}; // 实际发送速率（毫采样/秒），反馈校正
    long long accNum = 0;                // 小数累加器分子累加值
    int accDen = 8000;                   // 每包周期采样数分母（HS=8000，FS=1000）
    int64_t totalFrames = 0;             // 已发送帧数（进度参考）

    std::atomic<bool> running{false};
    std::atomic<bool> joined{false}; // 线程 join 完成标记（保证恰好 join 一次）
    pthread_t reapThread{};
    pthread_t fbThread{};
    bool fbThreadStarted = false;
    pthread_mutex_t ioMu = PTHREAD_MUTEX_INITIALIZER;
    std::atomic<long> underruns{0};
    int urbErrTotal = 0;    // URB 完成状态非 0 累计（线级无声取证，reap 线程累加）
};

static std::string gLastError;

// ---------------------------------------------------------------------------
// URB 位流抓取（bit-perfect 验证用；run-as <pkg> touch files/uac_cap.on 触发，无 root）
//   uac_cap_in.pcm  = nativeWrite 收到的解码 PCM（输入侧）
//   uac_cap_out.pcm = fillUrb 装进 URB 的线格式位流（= DAC 实收位）
//   uac_cap_meta.txt = 采样率/声道/位深/编码参数
// ---------------------------------------------------------------------------
static struct {
    FILE *in = nullptr;
    FILE *out = nullptr;
    long long inBytes = 0;
    long long outBytes = 0;
    bool checked = false;
    pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
} g_cap;
static const long long kCapMax = 512LL * 1024 * 1024; // 防爆盘上限 512MB

// 新会话重置采集：关闭旧文件、清计数、重新武装 flag 检查。
// （否则 g_cap.checked 每进程只武装一次，脚本删旧文件后新会话写进已删 inode。）
static void capReset() {
    pthread_mutex_lock(&g_cap.mu);
    if (g_cap.in) {
        fclose(g_cap.in);
        g_cap.in = nullptr;
    }
    if (g_cap.out) {
        fclose(g_cap.out);
        g_cap.out = nullptr;
    }
    g_cap.inBytes = 0;
    g_cap.outBytes = 0;
    g_cap.checked = false;
    pthread_mutex_unlock(&g_cap.mu);
}

static std::string capDir() {
    char pkg[256] = {0};
    int fd = open("/proc/self/cmdline", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, pkg, sizeof(pkg) - 1);
        (void) n;
        close(fd);
    }
    std::string p = pkg;
    if (p.empty()) p = "com.feiniu.music";
    return "/data/data/" + p + "/files";
}

static void capMaybeOpen(const UacOutput *o) {
    if (g_cap.checked) return;
    pthread_mutex_lock(&g_cap.mu);
    if (!g_cap.checked) {
        std::string dir = capDir();
        if (access((dir + "/uac_cap.on").c_str(), F_OK) == 0) {
            g_cap.in = fopen((dir + "/uac_cap_in.pcm").c_str(), "wb");
            g_cap.out = fopen((dir + "/uac_cap_out.pcm").c_str(), "wb");
            FILE *m = fopen((dir + "/uac_cap_meta.txt").c_str(), "w");
            if (m) {
                fprintf(m, "rate=%d ch=%d subframe=%d inEnc=%d wireFrame=%d hs=%d uac2=%d\n",
                        o->sampleRate, o->channels, o->alt.subframe, o->inEnc,
                        o->wireFrame, (int) o->highSpeed, (int) o->uac2);
                fclose(m);
            }
            LOGI("CAPTURE ON dir=%s", dir.c_str());
            g_cap.checked = true;
        }
    }
    pthread_mutex_unlock(&g_cap.mu);
}

static void capWrite(FILE *f, const uint8_t *p, size_t n, long long *counter) {
    if (!f || *counter >= kCapMax) return;
    pthread_mutex_lock(&g_cap.mu);
    if (f && *counter < kCapMax) {
        fwrite(p, 1, n, f);
        *counter += (long long) n;
        fflush(f);
    }
    pthread_mutex_unlock(&g_cap.mu);
}

// ---------------------------------------------------------------------------
// usbfs helpers
// ---------------------------------------------------------------------------
static bool ctrlTransfer(int fd, uint8_t type, uint8_t req, uint16_t value,
                         uint16_t index, void *data, uint16_t len, int timeoutMs = 1000) {
    usbdevfs_ctrltransfer ct{};
    ct.bRequestType = type;
    ct.bRequest = req;
    ct.wValue = value;
    ct.wIndex = index;
    ct.wLength = len;
    ct.timeout = timeoutMs;
    ct.data = data;
    long r = ioctl(fd, USBDEVFS_CONTROL, &ct);
    return r >= 0;
}

static int getSpeedFd(int fd) {
    // USBDEVFS_GET_SPEED：返回 usb_device_speed 枚举（3=HIGH, 2=FULL）。
    long r = ioctl(fd, _IO('U', 31), 0);
    return (int) r; // 负值=不支持该 ioctl，按全速处理
}

// ---------------------------------------------------------------------------
// 描述符解析
// ---------------------------------------------------------------------------
static void parseFormatType(const uint8_t *p, int len, AltSetting &alt) {
    // FORMAT_TYPE_I：bLength,type,sub,fmtType,bNrChannels,bSubframe,bBitRes,
    //                bSamFreqType,[tSamFreq*3 ...] 或 min/max（6 字节）
    if (len < 8) return;
    alt.channels = p[4];
    alt.subframe = p[5];
    alt.bitDepth = p[6];
    int freqType = p[7];
    if (freqType == 0 && len >= 14) {
        alt.rateMin = p[8] | (p[9] << 8) | (p[10] << 16);
        alt.rateMax = p[11] | (p[12] << 8) | (p[13] << 16);
    } else {
        for (int i = 0; i < freqType; i++) {
            int off = 8 + i * 3;
            if (off + 3 > len) break;
            alt.rates.push_back(p[off] | (p[off + 1] << 8) | (p[off + 2] << 16));
        }
    }
}

static bool parseConfigDescriptor(const uint8_t *buf, int total, DeviceInfo &out) {
    int pos = 0;
    int curIface = -1, curAlt = -1;
    bool inStreaming = false; // 当前接口是 AudioStreaming
    AltSetting cur;
    bool haveAlt = false;

    auto flushAlt = [&]() {
        if (haveAlt && cur.epAddr != 0 && cur.subframe > 0) {
            out.alts.push_back(cur);
        } else if (haveAlt) {
            LOGI("flushAlt reject: iface=%d alt=%d ep=0x%x subframe=%d ch=%d",
                 cur.iface, cur.alt, cur.epAddr, cur.subframe, cur.channels);
        }
        haveAlt = false;
        cur = AltSetting{};
    };

    while (pos + 2 <= total) {
        uint8_t bLength = buf[pos];
        uint8_t bType = buf[pos + 1];
        if (bLength < 2 || pos + bLength > total) break;
        const uint8_t *p = buf + pos;
        LOGI("desc type=0x%02x len=%d iface=%d alt=%d data=%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
             bType, bLength, curIface, curAlt,
             p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
             bLength > 8 ? p[8] : 0, bLength > 9 ? p[9] : 0,
             bLength > 10 ? p[10] : 0, bLength > 11 ? p[11] : 0,
             bLength > 12 ? p[12] : 0, bLength > 13 ? p[13] : 0,
             bLength > 14 ? p[14] : 0, bLength > 15 ? p[15] : 0);
        switch (bType) {
            case USB_DT_INTERFACE: {
                if (bLength >= 9) {
                    flushAlt();
                    curIface = p[2];
                    curAlt = p[3];
                    uint8_t cls = p[5], sub = p[6];
                    inStreaming = (cls == USB_CLASS_AUDIO && sub == 2);
                    if (cls == USB_CLASS_AUDIO && sub == 1) {
                        out.acIface = curIface;
                    }
                    if (inStreaming && curAlt > 0) {
                        cur.iface = curIface;
                        cur.alt = curAlt;
                        haveAlt = true;
                    }
                }
                break;
            }
            case USB_DT_ENDPOINT: {
                if (bLength >= 7 && haveAlt) {
                    uint8_t addr = p[2];
                    uint8_t attr = p[3];
                    if ((attr & USB_ENDPOINT_XFERTYPE_MASK) == USB_ENDPOINT_XFER_ISOC &&
                        (addr & USB_ENDPOINT_DIR_MASK) == 0) {
                        cur.epAddr = addr;
                        cur.syncType = (attr >> 2) & 0x3;
                        cur.maxPacket = p[4] | (p[5] << 8);
                    } else if ((attr & USB_ENDPOINT_XFERTYPE_MASK) == USB_ENDPOINT_XFER_INT &&
                               (addr & USB_ENDPOINT_DIR_MASK) != 0) {
                        cur.fbEpAddr = addr; // 显式反馈端点（IN）
                    }
                }
                break;
            }
            case USB_DT_CS_INTERFACE: {
                if (bLength >= 3 && !inStreaming) {
                    // AudioControl 内：Clock Source（UAC2）
                    if (p[2] == UAC2_CLOCK_SOURCE && bLength >= 8) {
                        out.uac2 = true;
                        out.clockId = p[3];
                    } else if (p[2] == UAC2_FEATURE_UNIT && bLength >= 4) {
                        out.fuId = p[3];
                    }
                } else if (bLength >= 3 && inStreaming && haveAlt) {
                    if (p[2] == CS_AS_GENERAL && bLength >= 16) {
                        // AS_GENERAL（UAC2）：bNrChannels 在 offset 10
                        // （16B 精简布局，如 TTGK ECHO-A；标准 17B 布局在 offset 11）。
                        cur.channels = (bLength >= 17) ? p[11] : p[10];
                    } else if (p[2] == CS_FORMAT_TYPE && p[3] == 0x01 /* FORMAT_TYPE_I */) {
                        if (bLength >= 8) {
                            parseFormatType(p, bLength, cur);
                        } else if (bLength == 6) {
                            // 精简 FORMAT_TYPE_I（ECHO-A 等 UAC2 小尾巴）：
                            // 只带 [bSubframeSize][bBitResolution]，声道数在
                            // AS_GENERAL，采样率无静态表（UAC2 时钟编程型）。
                            cur.subframe = p[4];
                            cur.bitDepth = p[5];
                        }
                    }
                }
                break;
            }
            case USB_DT_CS_ENDPOINT: {
                // UAC2 EP_GENERAL（bmControls 含 pitch/freq）——解析无需额外字段。
                break;
            }
            case USB_DT_CONFIG:
                break;
            default:
                break;
        }
        pos += bLength;
    }
    flushAlt();
    LOGI("parseConfig done: total=%d alts=%d uac2=%d clockId=%d acIface=%d",
         total, (int) out.alts.size(), out.uac2 ? 1 : 0, out.clockId, out.acIface);

    // UAC1 兜底：没有 clock source 时按 UAC1 频率控制（端点 SET_CUR）处理。
    return !out.alts.empty();
}

static bool readAndParseConfig(int fd, DeviceInfo &out) {
    uint8_t hdr[9];
    if (!ctrlTransfer(fd, USB_DIR_IN | USB_TYPE_STANDARD | USB_RECIP_DEVICE,
                      USB_REQ_GET_DESCRIPTOR, (USB_DT_CONFIG << 8), 0, hdr, 9)) {
        gLastError = "GET_DESCRIPTOR(config hdr) failed";
        return false;
    }
    int total = hdr[2] | (hdr[3] << 8);
    if (total < 9 || total > 4096) {
        gLastError = "bad config descriptor size";
        return false;
    }
    std::vector<uint8_t> buf(total);
    if (!ctrlTransfer(fd, USB_DIR_IN | USB_TYPE_STANDARD | USB_RECIP_DEVICE,
                      USB_REQ_GET_DESCRIPTOR, (USB_DT_CONFIG << 8), 0, buf.data(), total)) {
        gLastError = "GET_DESCRIPTOR(config) failed";
        return false;
    }
    out.highSpeed = getSpeedFd(fd) >= 3;
    return parseConfigDescriptor(buf.data(), total, out);
}

// 生成 JSON 描述（给 Kotlin 选 alt setting 用）。
static std::string deviceInfoJson(const DeviceInfo &d) {
    std::string j = "{\"uac2\":";
    j += d.uac2 ? "true" : "false";
    j += ",\"highSpeed\":";
    j += d.highSpeed ? "true" : "false";
    j += ",\"acIface\":" + std::to_string(d.acIface);
    j += ",\"clockId\":" + std::to_string(d.clockId);
    j += ",\"alts\":[";
    for (size_t i = 0; i < d.alts.size(); i++) {
        const AltSetting &a = d.alts[i];
        if (i) j += ",";
        j += "{\"iface\":" + std::to_string(a.iface);
        j += ",\"alt\":" + std::to_string(a.alt);
        j += ",\"ep\":" + std::to_string(a.epAddr);
        j += ",\"maxPacket\":" + std::to_string(a.maxPacket & 0x7ff);
        j += ",\"syncType\":" + std::to_string(a.syncType);
        j += ",\"fbEp\":" + std::to_string(a.fbEpAddr);
        j += ",\"channels\":" + std::to_string(a.channels);
        j += ",\"subframe\":" + std::to_string(a.subframe);
        j += ",\"bitDepth\":" + std::to_string(a.bitDepth);
        j += ",\"rateMin\":" + std::to_string(a.rateMin);
        j += ",\"rateMax\":" + std::to_string(a.rateMax);
        j += ",\"rates\":[";
        for (size_t k = 0; k < a.rates.size(); k++) {
            if (k) j += ",";
            j += std::to_string(a.rates[k]);
        }
        j += "]}";
    }
    j += "]}";
    return j;
}

// ---------------------------------------------------------------------------
// 时钟控制（UAC2 Clock Source SET_CUR / UAC1 端点 SET_CUR）
// ---------------------------------------------------------------------------
// UAC2 时钟 SET_CUR/GET_CUR：spec 要求 wIndex 低字节 = AC 接口号，但 AC 接口常被
// 系统 USB audio HAL 的 fd 长期 claim（小米15 实测：无内核驱动绑定、iface0 仍
// claim EBUSY = audioserver 播过 USB 后不放），usbfs 按 wIndex&0xff 校验本 fd 的
// claim → 原样发必 EBUSY（44.1k 时钟设不上 → DAC 跑默认 48k → 44.1k 曲子爆音）。
// 低字节换用我们已 claim 的 streaming 接口即可放行；多数 DAC 固件只取 (wIndex>>8)
// 为 entity id、低字节忽略。设备严格校验会 STALL，此时返回失败走原路径。
static bool uac2ClockCtrl(int fd, bool isIn, int req, int clockId, int acIface,
                          int streamIface, uint8_t *data, int len) {
    uint16_t wValue = (uint16_t) (SAMPLING_FREQ_CONTROL << 8);
    uint8_t rt = (uint8_t) ((isIn ? USB_DIR_IN : USB_DIR_OUT) | USB_TYPE_CLASS | USB_RECIP_INTERFACE);
    uint16_t wAc = (uint16_t) ((clockId << 8) | (acIface & 0xff));
    if (ctrlTransfer(fd, rt, req, wValue, wAc, data, len)) return true;
    int e1 = errno;
    if (streamIface >= 0 && streamIface != acIface) {
        uint16_t wStream = (uint16_t) ((clockId << 8) | (streamIface & 0xff));
        bool ok2 = ctrlTransfer(fd, rt, req, wValue, wStream, data, len);
        int e2 = errno;
        if (ok2) {
            LOGI("clock %s ok via stream iface=%d (acIf=%d rejected errno=%d)",
                 req == SET_CUR ? "SET_CUR" : "GET_CUR", streamIface, acIface, e1);
            return true;
        }
        LOGI("clock %s retry via stream iface=%d also failed errno=%d (acIf errno=%d)",
             req == SET_CUR ? "SET_CUR" : "GET_CUR", streamIface, e2, e1);
        errno = e2;
        return false;
    }
    errno = e1;
    return false;
}

static bool setSamplingFrequency(UacOutput *o, int rate) {
    // 先 claim AudioControl 接口：部分设备/内核对未 claim 的接口拒发 class 控制传输（EBUSY）
    if (o->acIface >= 0) {
        unsigned int ifn = (unsigned int) o->acIface;
        int cr = ioctl(o->fd, USBDEVFS_CLAIMINTERFACE, &ifn);
        LOGI("claim AudioControl iface=%d %s errno=%d", o->acIface,
             cr == 0 ? "ok" : "failed", cr == 0 ? 0 : errno);
    }
    bool setOk = false;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) usleep(20 * 1000);
        bool ok = false;
        if (o->uac2) {
            // UAC2：SET_CUR(SAMPLING_FREQ) → Clock Source Entity（见 uac2ClockCtrl 注释）
            uint8_t data[4] = {(uint8_t) (rate & 0xff), (uint8_t) ((rate >> 8) & 0xff),
                               (uint8_t) ((rate >> 16) & 0xff), 0};
            ok = uac2ClockCtrl(o->fd, false, SET_CUR, o->clockId, o->acIface,
                               o->alt.iface, data, 4);
        } else {
            // UAC1：SET_CUR(SAMPLING_FREQ) → 等时端点，3 字节
            uint8_t data[3] = {(uint8_t) (rate & 0xff), (uint8_t) ((rate >> 8) & 0xff),
                               (uint8_t) ((rate >> 16) & 0xff)};
            uint16_t wValue = (SAMPLING_FREQ_CONTROL << 8);
            ok = ctrlTransfer(o->fd, USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_ENDPOINT,
                              SET_CUR, wValue, (uint16_t) o->alt.epAddr, data, 3);
        }
        if (ok) {
            LOGI("setSamplingFrequency(%d) ok attempt=%d", rate, attempt);
            setOk = true;
            break;
        }
        LOGI("setSamplingFrequency(%d) attempt=%d failed errno=%d", rate, attempt, errno);
    }
    // 诊断：GET_CUR 读回设备当前时钟值（SET_CUR 是否真生效的实锤）
    {
        uint8_t g[4] = {0};
        bool got;
        if (o->uac2) {
            got = uac2ClockCtrl(o->fd, true, GET_CUR, o->clockId, o->acIface,
                                o->alt.iface, g, 4);
        } else {
            uint16_t wValue = (uint16_t) (SAMPLING_FREQ_CONTROL << 8);
            got = ctrlTransfer(o->fd, USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_ENDPOINT,
                               GET_CUR, wValue, (uint16_t) o->alt.epAddr, g, 3);
        }
        if (got) {
            int cur = g[0] | (g[1] << 8) | (g[2] << 16);
            LOGI("device clock GET_CUR = %d Hz (requested %d)", cur, rate);
        } else {
            LOGI("device clock GET_CUR failed errno=%d", errno);
        }
    }
    if (setOk) return true;
    // ---- ECHO-A 归因探针 + alt0 暂停期时钟重编程（爆音根因排查 2026-09-25）----
    // 探针 1：标准 GET_DESCRIPTOR（设备级请求）也走同一 USBDEVFS_CONTROL 通路——
    // 若它也 EBUSY = 通路级占用（内核/系统栈）；若成功 = 仅 class 接口请求被拒。
    {
        uint8_t d[18] = {0};
        bool dok = ctrlTransfer(o->fd, USB_DIR_IN | USB_TYPE_STANDARD | USB_RECIP_DEVICE,
                                0x06 /* GET_DESCRIPTOR */, (USB_DT_DEVICE << 8), 0, d, 18);
        LOGI("clock probe: GET_DESCRIPTOR device %s errno=%d", dok ? "ok" : "failed",
             dok ? 0 : errno);
    }
    // 探针 2：退 alt0（流管线停在 idle alt）→ SET_CUR → 恢复原 alt。部分 DAC 只在
    // 非 streaming alt 下接受时钟编程（streaming 中 SET_CUR 回 busy）。
    {
        struct usbdevfs_setinterface sif0;
        sif0.interface = (unsigned int) o->alt.iface;
        sif0.altsetting = 0;
        struct usbdevfs_setinterface sifBack;
        sifBack.interface = (unsigned int) o->alt.iface;
        sifBack.altsetting = (unsigned int) o->alt.alt;
        if (ioctl(o->fd, USBDEVFS_SETINTERFACE, &sif0) == 0) {
            usleep(10 * 1000);
            uint8_t data[4] = {(uint8_t) (rate & 0xff), (uint8_t) ((rate >> 8) & 0xff),
                               (uint8_t) ((rate >> 16) & 0xff), 0};
            bool okAlt0;
            if (o->uac2) {
                okAlt0 = uac2ClockCtrl(o->fd, false, SET_CUR, o->clockId, o->acIface,
                                       o->alt.iface, data, 4);
            } else {
                uint16_t wValue = (uint16_t) (SAMPLING_FREQ_CONTROL << 8);
                okAlt0 = ctrlTransfer(o->fd, USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_ENDPOINT,
                                      SET_CUR, wValue, (uint16_t) o->alt.epAddr, data, 3);
            }
            if (ioctl(o->fd, USBDEVFS_SETINTERFACE, &sifBack) < 0) {
                LOGE("alt0 probe: restore alt=%d failed errno=%d", o->alt.alt, errno);
            }
            if (okAlt0) {
                LOGI("setSamplingFrequency(%d) ok via alt0 idle (clock reprogrammed)", rate);
                setOk = true;
            } else {
                LOGI("alt0 idle clock SET_CUR failed errno=%d", errno);
            }
        } else {
            LOGI("alt0 probe: SETINTERFACE failed errno=%d", errno);
        }
    }
    if (setOk) return true;
    // 最终失败只降级警告：adaptive/sync 型 DAC 跟随位流速率，不依赖 SET_CUR；不中断启动
    LOGI("setSamplingFrequency(%d) failed errno=%d (adaptive DAC keeps stream clock, continue)", rate, errno);
    return false;
}

// ---------------------------------------------------------------------------
// PCM 环形缓冲（输入编码字节流）
// ---------------------------------------------------------------------------
static size_t ringUsed(UacOutput *o) {
    size_t w = o->ringW.load(std::memory_order_acquire);
    size_t r = o->ringR.load(std::memory_order_relaxed);
    return w >= r ? w - r : o->ringCap - r + w;
}

static size_t ringFree(UacOutput *o) { return o->ringCap - 1 - ringUsed(o); }

// 阻塞写入（回压= DAC 时钟同步；decent-player 的做法：reap 提供时钟背压）。
static bool ringWrite(UacOutput *o, const uint8_t *src, size_t len) {
    pthread_mutex_lock(&o->ringMu);
    while (o->running.load() && ringFree(o) < len) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 200 * 1000 * 1000;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
        pthread_cond_timedwait(&o->ringCond, &o->ringMu, &ts);
    }
    if (!o->running.load()) {
        pthread_mutex_unlock(&o->ringMu);
        return false;
    }
    size_t w = o->ringW.load(std::memory_order_relaxed);
    for (size_t i = 0; i < len; i++) {
        o->ring[(w + i) % o->ringCap] = src[i];
    }
    o->ringW.store((w + len) % o->ringCap, std::memory_order_release);
    pthread_cond_broadcast(&o->ringCond);
    pthread_mutex_unlock(&o->ringMu);
    return true;
}

// 消费 len 字节（不足补零，计 underrun）。
static void ringRead(UacOutput *o, uint8_t *dst, size_t len) {
    size_t used = ringUsed(o);
    size_t take = used < len ? used : len;
    size_t r = o->ringR.load(std::memory_order_relaxed);
    for (size_t i = 0; i < take; i++) {
        dst[i] = o->ring[(r + i) % o->ringCap];
    }
    o->ringR.store((r + take) % o->ringCap, std::memory_order_release);
    if (take < len) {
        memset(dst + take, 0, len - take); // 静音补零（不引入杂讯）
        long n = o->underruns.fetch_add(1) + 1;
        // 限频：首次 + 每 50 次一条（underrun=听感卡顿，必须可见）
        if (n == 1 || n % 50 == 0) {
            LOGI("underrun total=%ld have=%zu need=%zu ring=%zu/%zu", n, take, len,
                 ringUsed(o), o->ringCap);
        }
    }
    pthread_mutex_lock(&o->ringMu);
    pthread_cond_broadcast(&o->ringCond);
    pthread_mutex_unlock(&o->ringMu);
}

// ---------------------------------------------------------------------------
// 输入编码 → DAC 线格式（全程整数位移，匹配位深时 bit-perfect）
// ---------------------------------------------------------------------------
// 载入一个采样并归一到 32 位刻度（升位=左移补零，精确；float=满幅转换）。
static int32_t loadSample32(const uint8_t *sp, int inEnc) {
    int32_t v = 0;
    switch (inEnc) {
        case ENC_PCM_16:
            v = (int32_t) (int16_t) (sp[0] | (sp[1] << 8));
            v <<= 16; // 16 → 32 精确升位
            break;
        case ENC_PCM_24_PACKED:
            v = (int32_t) ((sp[0] | (sp[1] << 8) | (sp[2] << 16)) << 8) >> 8; // 符号扩展 24→32
            v <<= 8; // 24 → 32 精确升位
            break;
        case ENC_PCM_FLOAT: {
            // MediaCodec 偶发浮点输出：满幅转整数（非位透明，数值等价）。
            float fv;
            memcpy(&fv, sp, 4);
            double x = (double) fv * 2147483647.0;
            if (x > 2147483647.0) x = 2147483647.0;
            if (x < -2147483648.0) x = -2147483648.0;
            v = (int32_t) x;
            break;
        }
        case ENC_PCM_32:
        default:
            v = (int32_t) (sp[0] | (sp[1] << 8) | (sp[2] << 16) | ((uint32_t) sp[3] << 24));
            break;
    }
    return v;
}

static void storeSample(uint8_t *d, int32_t v, int outSample) {
    switch (outSample) {
        case 2:
            d[0] = (uint8_t) ((v >> 16) & 0xff);
            d[1] = (uint8_t) ((v >> 24) & 0xff);
            break;
        case 3:
            d[0] = (uint8_t) ((v >> 8) & 0xff);
            d[1] = (uint8_t) ((v >> 16) & 0xff);
            d[2] = (uint8_t) ((v >> 24) & 0xff);
            break;
        default:
            d[0] = (uint8_t) (v & 0xff);
            d[1] = (uint8_t) ((v >> 8) & 0xff);
            d[2] = (uint8_t) ((v >> 16) & 0xff);
            d[3] = (uint8_t) ((v >> 24) & 0xff);
            break;
    }
}

// TPDF dither：仅当 DAC 位深 < 源位深（降位有损）时加三角形噪声再截断，
// 避免量化失真（THD）集中成谐波。匹配位深时不调用（保持 bit-perfect）。
static int32_t ditherSample(UacOutput *o, int32_t v, int outSample) {
    int shift = 32 - outSample * 8;
    if (shift <= 0) return v;
    o->ditherSeed = o->ditherSeed * 1664525u + 1013904223u;
    uint32_t r1 = (o->ditherSeed >> 8) & 0xffffu;
    o->ditherSeed = o->ditherSeed * 1664525u + 1013904223u;
    uint32_t r2 = (o->ditherSeed >> 8) & 0xffffu;
    int64_t noise = ((int64_t) r1 - (int64_t) r2) * (1LL << shift) / 65536; // ±1 LSB
    int64_t out = (int64_t) v + noise;
    if (out > INT32_MAX) out = INT32_MAX;
    if (out < INT32_MIN) out = INT32_MIN;
    return (int32_t) out;
}

// 声道映射：out 声道 j ← in 声道组 [j*inCh/outCh, (j+1)*inCh/outCh) 的均值。
// 同声道数=直通（bit-perfect）；单声道→多声道=复制（无损）；
// 多声道→少声道=分组下混（数值正确，但非位透明——本就非位透明场景）。
// 若 wireRate≠sampleRate（DAC 不支持源采样率，取最接近率协商），随后做
// 线性插值重采样（跨调用保持相位）——牺牲 bit-perfect 换取能播。
// 返回写入 out 的实际字节数；out 容量需 ≥ 最大输出帧数*outSample。
static size_t convertFrames(UacOutput *o, const uint8_t *in, size_t inBytes,
                            uint8_t *out, size_t outCap) {
    const int inCh = o->channels;                     // 源声道数
    const int outCh = o->alt.channels > 0 ? o->alt.channels : inCh; // DAC 声道数
    const int inSample = o->inFrame / inCh;      // 输入每采样字节（2/3/4）
    const int outSample = o->alt.subframe;     // 输出每采样字节（2/3/4）
    const size_t frames = inBytes / o->inFrame;
    const bool resample = (o->wireRate != o->sampleRate);
    const bool ditherDown = (o->srcBits > outSample * 8);

    // 1) 声道映射到 int32（outCh 交织）——统一中间刻度，升位精确。
    std::vector<int32_t> mapped(frames * (size_t) outCh);
    const uint8_t *s = in;
    for (size_t f = 0; f < frames; f++) {
        for (int c = 0; c < outCh; c++) {
            int g0 = (int) (((int64_t) c) * inCh / outCh);
            int g1 = (int) (((int64_t) (c + 1)) * inCh / outCh);
            if (g1 <= g0) g1 = g0 + 1;
            int64_t sum = 0;
            for (int sc = g0; sc < g1; sc++) {
                sum += loadSample32(s + (size_t) sc * inSample, o->inEnc);
            }
            mapped[f * (size_t) outCh + c] = (int32_t) (sum / (g1 - g0));
        }
        s += o->inFrame;
    }

    uint8_t *d = out;
    if (!resample) {
        // 2a) 直通：逐采样存储（匹配位深时 bit-perfect）。
        for (size_t f = 0; f < frames; f++) {
            for (int c = 0; c < outCh; c++) {
                int32_t v = mapped[f * (size_t) outCh + c];
                if (ditherDown) v = ditherSample(o, v, outSample);
                storeSample(d, v, outSample);
                d += outSample;
            }
        }
    } else {
        // 2b) 线性插值重采样：step=每输出帧消耗的输入帧数。
        // rsPrev=上一输入帧（跨调用），rsFrac∈[0,1)=当前插值相位。
        if ((int) o->rsPrev.size() != outCh) o->rsPrev.assign(outCh, 0);
        const double step = (double) o->sampleRate / (double) o->wireRate;
        size_t i = 0;
        while (true) {
            if (o->rsFrac >= 1.0) { // 相位越过输入帧 → 推进
                if (i >= frames) break;
                for (int c = 0; c < outCh; c++) o->rsPrev[c] = mapped[i * (size_t) outCh + c];
                i++;
                o->rsFrac -= 1.0;
                continue;
            }
            if (i >= frames) break;
            if ((size_t) (d - out) + (size_t) outSample * outCh > outCap) break; // 容量安全阀
            for (int c = 0; c < outCh; c++) {
                double a = (double) o->rsPrev[c];
                double b = (double) mapped[i * (size_t) outCh + c];
                int32_t v = (int32_t) (a + (b - a) * o->rsFrac);
                if (ditherDown) v = ditherSample(o, v, outSample);
                storeSample(d, v, outSample);
                d += outSample;
            }
            o->rsFrac += step;
        }
    }
    return (size_t) (d - out);
}

// ---------------------------------------------------------------------------
// 每包采样数规划（小数累加器，处理 44.1k/88.2k 等非整数周期）
// ---------------------------------------------------------------------------
static int planPacketBytes(UacOutput *o) {
    // 每包（8 微帧 HS / 1 帧 FS）采样数 = rateMilli/1000 / accDen 的小数累加。
    long long rate = o->rateMilli.load(); // 毫采样/秒
    o->accNum += rate / 1000;
    int n = (int) (o->accNum / o->accDen);
    o->accNum -= (long long) n * o->accDen;
    if (n <= 0) n = 1;
    return n * o->wireFrame;
}

// ---------------------------------------------------------------------------
// 显式反馈端点（ASYNC DAC）：读设备反馈（HS 16.16 / FS 10.14），微调发送速率
// ---------------------------------------------------------------------------
static void *fbThreadMain(void *arg) {
    UacOutput *o = (UacOutput *) arg;
    if (o->alt.fbEpAddr == 0) return nullptr;
    const int fbMax = o->highSpeed ? 4 : 3;
    uint8_t fb[8];
    while (o->running.load()) {
        usbdevfs_urb urb{};
        urb.type = USBDEVFS_URB_TYPE_ISO; // 部分设备反馈走中断端点，ISO 提交失败则按 INT
        urb.endpoint = (unsigned char) o->alt.fbEpAddr;
        urb.buffer = fb;
        urb.buffer_length = fbMax;
        if (ioctl(o->fd, USBDEVFS_SUBMITURB, &urb) < 0) {
            urb.type = USBDEVFS_URB_TYPE_INTERRUPT;
            if (ioctl(o->fd, USBDEVFS_SUBMITURB, &urb) < 0) {
                usleep(1000);
                continue;
            }
        }
        void *reaped = nullptr;
        struct pollfd pfd{};
        pfd.fd = o->fd;
        pfd.events = POLLIN;
        while (o->running.load()) {
            int pr = poll(&pfd, 1, 50);
            if (pr <= 0) continue;
            if (ioctl(o->fd, USBDEVFS_REAPURBNDELAY, &reaped) == 0) break;
        }
        // 解析反馈值 → 校正发送速率（±1% 以内跟随设备时钟）
        long long base = (long long) o->wireRate * 1000; // 线上按协商率计
        long long actual = base;
        uint32_t raw = fb[0] | (fb[1] << 8) | (fb[2] << 16) | ((uint32_t) fb[3] << 24);
        if (o->highSpeed) {
            // 16.16：每微帧采样数 * 8000
            double perUframe = (double) raw / 65536.0;
            actual = (long long) (perUframe * 8000.0 * 1000.0);
        } else {
            // 10.14：每帧采样数 * 1000
            double perFrame = (double) (raw >> 2) / 16384.0; // 10.14 取 20 位
            perFrame = (double) raw / 16384.0;
            actual = (long long) (perFrame * 1000.0 * 1000.0);
        }
        bool accept = actual > base * 98 / 100 && actual < base * 102 / 100;
        static std::atomic<int> fbN{0};
        int c = fbN.fetch_add(1);
        if (c < 3 || c % 400 == 0) {
            LOGI("fb raw=%u actual=%lld base=%lld %s", raw, (long long) actual,
                 (long long) base, accept ? "accepted" : "REJECTED");
        }
        if (accept) {
            o->rateMilli.store(actual);
        }
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// fillUrb：从环形缓冲取数据填充一个 ISO URB（reap 线程与初始投递共用）。
// ---------------------------------------------------------------------------
static void fillUrb(UacOutput *o, usbdevfs_urb *urb, std::vector<uint8_t> &buf) {
    capMaybeOpen(o);
    int periodDen = o->accDen;
    int total = 0;
    int maxPacket = o->alt.maxPacket & 0x7ff;
    for (int i = 0; i < urb->number_of_packets; i++) {
        int want = planPacketBytes(o);
        if (want > maxPacket) want = maxPacket;
        if (total + want > (int) buf.size()) want = (int) buf.size() - total;
        if (want < 0) want = 0;
        // 数据包规划字节不足一帧时对齐到帧边界（DAC 忌讳碎帧）
        want -= want % o->wireFrame;
        if (want == 0) want = o->wireFrame;
        ringRead(o, buf.data() + total, (size_t) want);
        urb->iso_frame_desc[i].length = (unsigned int) want;
        total += want;
    }
    urb->buffer = buf.data();
    urb->buffer_length = total;
    o->totalFrames += total / o->wireFrame;
    // 抓取点：本 URB 实际送出的全部位（= USB 总线上 DAC 收到的位）
    capWrite(g_cap.out, buf.data(), (size_t) total, &g_cap.outBytes);
    (void) periodDen;
}

// 带自愈的 URB 提交：端点可能被并发 reconfigure——典型场景是本会话 setInterface
// 之后，系统 ALSA 流（前一轮 audiotrack-fallback / ExoPlayer 降级流）拆流或重配
// 又改了 alt，SUBMITURB 报 ENOENT（当前 alt 查无此端点）。此时重申自己的 alt 让
// 内核重新选端点并分配等时带宽，再重投；比指数退避死等强：退避期间 ring 只进
// 不出 → 写满 → nativeWrite -1 → 上层 "usb write failed" → 强制降级 just_audio
// 与本会话互殴 = 爆音（2026-09-25 ECHO-A 实锤，见 HANDOFF §4）。
static bool submitUrbRecover(UacOutput *o, usbdevfs_urb *urb) {
    if (ioctl(o->fd, USBDEVFS_SUBMITURB, urb) == 0) return true;
    int se = errno;
    if (se == ENOENT || se == EINVAL) {
        struct usbdevfs_setinterface sif{};
        sif.interface = (unsigned int) o->alt.iface;
        sif.altsetting = (unsigned int) o->alt.alt;
        if (ioctl(o->fd, USBDEVFS_SETINTERFACE, &sif) == 0 &&
            ioctl(o->fd, USBDEVFS_SUBMITURB, urb) == 0) {
            LOGI("endpoint recovered via re-assert iface=%d alt=%d (submit errno=%d)",
                 o->alt.iface, o->alt.alt, se);
            return true;
        }
        LOGE("endpoint recovery failed (submit errno=%d reassert errno=%d)", se, errno);
    }
    return false;
}

// Reaper 线程：回收完成的 URB，补数据重投（阻塞 REAPURB = DAC 时钟背压）
static void *reapThreadMain(void *arg) {
    UacOutput *o = (UacOutput *) arg;
    int consecFail = 0;
    while (o->running.load()) {
        void *ptr = nullptr;
        long r = ioctl(o->fd, USBDEVFS_REAPURB, &ptr);
        if (!o->running.load()) break;
        if (r < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            // 设备拔出/挂起：ENODEV/ESHUTDOWN/EIO 时继续重试无意义，直接退出
            // （上层 write 失败 → 优雅降级到系统输出，不崩）。
            if (errno == ENODEV || errno == ESHUTDOWN || errno == EIO) {
                LOGE("REAPURB fatal errno=%d (device gone?), reap thread exit", errno);
                o->running.store(false);
                break;
            }
            LOGE("REAPURB failed: %d", errno);
            usleep(2000);
            continue;
        }
        auto *urb = (usbdevfs_urb *) ptr;
        // 所有权校验：usercontext 记录了 URB 下标，指针不匹配=旧会话残留的
        // 悬垂 URB（dup fd 共享 dev_state 完成队列），绝不能再写/提交（UAF）。
        size_t idx = (size_t) (uintptr_t) urb->usercontext;
        bool owned = idx < o->urbs.size() && o->urbs[idx] == urb;
        if (!owned) {
            LOGE("drop stale URB ptr=%p idx=%zu (old session leftover)", (void *) urb, idx);
            continue;
        }
        if (!o->running.load()) break;
        if (urb->status != 0) {
            o->urbErrTotal++;
            if (o->urbErrTotal == 1 || (o->urbErrTotal % 400) == 0)
                LOGI("URB completion err total=%d last=%d idx=%zu",
                     o->urbErrTotal, urb->status, idx);
        }
        fillUrb(o, urb, o->urbBuf[idx]);
        urb->flags = USBDEVFS_URB_ISO_ASAP;
        if (!submitUrbRecover(o, urb)) {
            // 指数退避：1ms→2→4→…→256ms 封顶（P2-8）。EINVAL 多为竞态瞬态
            // （P0-2），退避后重试通常自愈；连续 32 次失败才认输自杀。
            consecFail++;
            int shift = consecFail > 8 ? 8 : consecFail; // 2^8=256ms 封顶
            useconds_t backoff = (useconds_t) (1000u << (shift - 1));
            LOGE("resubmit URB failed: %d (consec=%d backoff=%uus)", errno, consecFail, backoff);
            if (consecFail > 32) {
                LOGE("resubmit failed %d times in a row, reap thread exit (graceful degrade)", consecFail);
                o->running.store(false);
                break;
            }
            usleep(backoff);
        } else {
            consecFail = 0;
        }
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// 设备侧探针（2026-09-26 直接切歌无声 bug）：host 侧链路全绿（setInterface ok /
// 时钟 SET_CUR ok / 线级采集 bit-perfect）但用户没声时，查两个设备侧可证伪点：
//   1) GET_INTERFACE 读设备自己报的 alt —— 与我们选的不一致 = 设备没真开流，
//      等时包全被丢弃（host 毫无察觉，采集照样 bit-perfect）。
//   2) Feature Unit MUTE/VOLUME —— 系统 ALSA（拔插重配/UsbAlsa）可能留下静音或
//      衰减，DAC 收满完美数据也不出声。发现 mute!=0 或 vol<0 就地解除。
// 任何失败只打日志，绝不影响启动（探针在 URB 投递之前跑一次）。
static void deviceProbe(UacOutput *o) {
    uint8_t alt = 0xFF;
    if (ctrlTransfer(o->fd, 0x81 /*IN|STANDARD|INTERFACE*/, 0x0A /*GET_INTERFACE*/,
                     0, (uint16_t) o->alt.iface, &alt, 1, 200)) {
        LOGI("probe: device reports alt=%u (we selected %d)", alt, o->alt.alt);
        if (alt != (uint8_t) o->alt.alt) {
            struct usbdevfs_setinterface sif{};
            sif.interface = (unsigned int) o->alt.iface;
            sif.altsetting = (unsigned int) o->alt.alt;
            int r = ioctl(o->fd, USBDEVFS_SETINTERFACE, &sif);
            LOGI("probe: alt MISMATCH -> re-assert iface=%d alt=%d ioctl=%d errno=%d",
                 o->alt.iface, o->alt.alt, r, r < 0 ? errno : 0);
            uint8_t alt2 = 0xFF;
            if (ctrlTransfer(o->fd, 0x81, 0x0A, 0, (uint16_t) o->alt.iface, &alt2, 1, 200))
                LOGI("probe: device alt now=%u", alt2);
        }
    } else {
        LOGI("probe: GET_INTERFACE failed errno=%d", errno);
    }

    DeviceInfo d;
    bool parsed = readAndParseConfig(o->fd, d);
    if (!parsed || d.fuId == 0) {
        LOGI("probe: no feature unit (parse=%d fuId=%d)", parsed ? 1 : 0, d.fuId);
        return;
    }
    uint16_t wIdxAc = (uint16_t) ((d.fuId << 8) | (d.acIface & 0xff));
    uint16_t wIdxSt = (uint16_t) ((d.fuId << 8) | (o->alt.iface & 0xff));
    uint8_t one = 0xFF;
    // MUTE：UAC2 wValue=(CS<<8)|CN；UAC1 wValue=(CN<<8)|CS —— 两种编码都试
    bool gotMute = ctrlTransfer(o->fd, 0xA1, 0x81 /*GET_CUR*/, 0x0100, wIdxAc, &one, 1, 200) ||
                   ctrlTransfer(o->fd, 0xA1, 0x81, 0x0100, wIdxSt, &one, 1, 200) ||
                   ctrlTransfer(o->fd, 0xA1, 0x81, 0x0001, wIdxAc, &one, 1, 200);
    if (gotMute) {
        LOGI("probe: FU mute=%u fuId=%d acIf=%d", one, d.fuId, d.acIface);
        if (one != 0) {
            uint8_t z = 0;
            bool cleared = ctrlTransfer(o->fd, 0x21, 0x01 /*SET_CUR*/, 0x0100, wIdxAc, &z, 1, 200) ||
                           ctrlTransfer(o->fd, 0x21, 0x01, 0x0100, wIdxSt, &z, 1, 200) ||
                           ctrlTransfer(o->fd, 0x21, 0x01, 0x0001, wIdxAc, &z, 1, 200);
            LOGI("probe: FU UNMUTE attempt -> %s", cleared ? "ok" : "failed");
        }
    } else {
        LOGI("probe: FU GET_MUTE failed errno=%d", errno);
    }

    uint8_t vol[4] = {0, 0, 0, 0};
    bool gotVol = ctrlTransfer(o->fd, 0xA1, 0x81 /*GET_CUR*/, 0x0200, wIdxAc, vol, 4, 200) ||
                  ctrlTransfer(o->fd, 0xA1, 0x81, 0x0200, wIdxSt, vol, 4, 200) ||
                  ctrlTransfer(o->fd, 0xA1, 0x81, 0x0002, wIdxAc, vol, 4, 200);
    if (gotVol) {
        int16_t vl = (int16_t) (vol[0] | (vol[1] << 8));
        int16_t vr = (int16_t) (vol[2] | (vol[3] << 8));
        LOGI("probe: FU vol L=%d R=%d (0.1dB)", vl, vr);
        if (vl < 0 || vr < 0) {
            uint8_t uni[4] = {0, 0, 0, 0}; // 0x0000 = 0dB 透明
            bool fixed = ctrlTransfer(o->fd, 0x21, 0x01, 0x0200, wIdxAc, uni, 4, 200) ||
                         ctrlTransfer(o->fd, 0x21, 0x01, 0x0200, wIdxSt, uni, 4, 200);
            LOGI("probe: FU vol set 0dB -> %s", fixed ? "ok" : "failed");
        }
    } else {
        LOGI("probe: FU GET_VOL failed errno=%d", errno);
    }
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_feiniu_usb_1audio_1exclusive_NativeUac_nativeParse(JNIEnv *env, jclass, jint fd) {
    DeviceInfo info;
    bool ok = readAndParseConfig(fd, info);
    if (!ok) {
        std::string j = "{\"error\":\"";
        j += gLastError.empty() ? "parse failed" : gLastError;
        j += "\",\"alts\":[]}";
        return env->NewStringUTF(j.c_str());
    }
    return env->NewStringUTF(deviceInfoJson(info).c_str());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_feiniu_usb_1audio_1exclusive_NativeUac_nativeStart(
        JNIEnv *, jclass,
        jint fd, jint iface, jint alt, jint epAddr, jint maxPacket, jint fbEp,
        jint syncType, jint sampleRate, jint wireRate, jint channels, jint altChannels,
        jint subframe, jint srcBits, jint inEnc, jboolean highSpeed, jboolean uac2,
        jint clockId, jint acIface) {
    capReset(); // 新会话：采集重新武装（flag 检查每会话一次）
    auto *o = new UacOutput();
    o->fd = dup(fd);
    if (o->fd < 0) {
        gLastError = "dup(fd) failed";
        delete o;
        return 0;
    }
    o->alt.iface = iface;
    o->alt.alt = alt;
    o->alt.epAddr = epAddr;
    o->alt.maxPacket = maxPacket;
    o->alt.fbEpAddr = fbEp;
    o->alt.syncType = syncType;
    o->alt.channels = altChannels > 0 ? altChannels : channels;
    o->alt.subframe = subframe;
    o->alt.bitDepth = subframe * 8;
    o->uac2 = uac2;
    o->highSpeed = highSpeed;
    o->acIface = acIface;
    o->clockId = clockId;
    o->sampleRate = sampleRate;
    o->wireRate = wireRate > 0 ? wireRate : sampleRate; // 协商率（DAC 最接近支持率）
    o->srcBits = srcBits > 0 ? srcBits : 16;
    o->channels = channels;
    o->inEnc = inEnc;
    int inSample = (inEnc == ENC_PCM_24_PACKED) ? 3 : (inEnc == ENC_PCM_16 ? 2 : 4);
    o->inFrame = inSample * channels;
    o->wireFrame = subframe * o->alt.channels; // 线上帧长=DAC 声道数（非源声道数）
    o->accDen = highSpeed ? 8000 : 1000;
    o->rateMilli.store((long long) o->wireRate * 1000); // 线上速率按协商率规划

    // 帧长必须能放进一个 USB 包（超长=配置错误，拒绝启动走常规回退）
    {
        int mp = o->alt.maxPacket & 0x7ff;
        if (mp <= 0 || o->wireFrame <= 0 || o->wireFrame > mp) {
            gLastError = "wireFrame exceeds maxPacket";
            LOGE("nativeStart reject: wireFrame=%d maxPacket=%d", o->wireFrame, mp);
            close(o->fd);
            delete o;
            return 0;
        }
    }

    if (!setSamplingFrequency(o, o->wireRate)) {
        LOGE("setSamplingFrequency(%d) failed errno=%d", o->wireRate, errno);
        // 不中止：部分 SYNC 型 DAC 忽略频率控制也能播。继续。
    }

    deviceProbe(o); // 设备侧探针（alt/静音/音量），失败仅打日志

    // PCM 环形缓冲 ≈ 200ms（回压点），URB 缓冲按最大包分配。
    // 重采样时线上产出多于输入（44.1k→48k ≈ +9%），按线上率+余量分配。
    size_t bytesPerSec = (size_t) o->wireFrame * (size_t) o->wireRate;
    o->ringCap = bytesPerSec / 5 + 64 * 1024;
    o->ring.resize(o->ringCap);

    int mp = o->alt.maxPacket & 0x7ff;
    o->urbs.resize(NUM_URBS, nullptr);
    o->urbBuf.resize(NUM_URBS);
    for (int i = 0; i < NUM_URBS; i++) {
        auto *urb = (usbdevfs_urb *) calloc(1, sizeof(usbdevfs_urb) +
                                              PACKETS_PER_URB * sizeof(usbdevfs_iso_packet_desc));
        urb->type = USBDEVFS_URB_TYPE_ISO;
        urb->endpoint = (unsigned char) epAddr;
        urb->flags = USBDEVFS_URB_ISO_ASAP;
        urb->number_of_packets = PACKETS_PER_URB;
        urb->usercontext = (void *) (long) i;
        o->urbs[i] = urb;
        o->urbBuf[i].resize((size_t) mp * PACKETS_PER_URB);
    }

    o->running.store(true);

    // 首次填充并全部投递（建立 80ms 管线）。
    for (int i = 0; i < NUM_URBS; i++) {
        fillUrb(o, o->urbs[i], o->urbBuf[i]);
        if (!submitUrbRecover(o, o->urbs[i])) {
            LOGE("initial SUBMITURB %d failed errno=%d", i, errno);
        }
    }

    pthread_create(&o->reapThread, nullptr, reapThreadMain, o);
    if (o->alt.fbEpAddr != 0 && syncType == 1 /* ASYNC */) {
        if (pthread_create(&o->fbThread, nullptr, fbThreadMain, o) == 0) {
            o->fbThreadStarted = true;
        }
    }
    LOGI("UAC start: rate=%d ch=%d subframe=%d ep=0x%02x urbs=%d hs=%d uac2=%d sync=%d fb=0x%02x clockId=%d acIf=%d",
         sampleRate, channels, subframe, epAddr, NUM_URBS, highSpeed, uac2,
         o->alt.syncType, o->alt.fbEpAddr, o->clockId, o->acIface);
    return reinterpret_cast<jlong>(o);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_feiniu_usb_1audio_1exclusive_NativeUac_nativeWrite(
        JNIEnv *env, jclass, jlong handle, jbyteArray data, jint offset, jint len) {
    auto *o = reinterpret_cast<UacOutput *>(handle);
    if (!o || len <= 0) return 0;
    // 已停止/管线死亡 → 返回 -1（不是 0！）：Kotlin write() 以 >=0 判成功，
    // 返回 0 会被误判成功导致解码线程永远"写进虚空"（P2-8 降级语义）。
    if (!o->running.load()) return -1;
    std::vector<uint8_t> in((size_t) len);
    env->GetByteArrayRegion(data, offset, len, (jbyte *) in.data());

    // 转成 DAC 线格式后入环（帧对齐）。重采样时输出帧数≠输入帧数，
    // 按最坏情况（上采样 +9% + 相位残帧）分配输出缓冲，convertFrames 返回实际字节。
    size_t frames = (size_t) len / o->inFrame;
    // 抓取点：解码器交来的 PCM（输入侧）
    capMaybeOpen(o);
    capWrite(g_cap.in, in.data(), frames * o->inFrame, &g_cap.inBytes);
    size_t maxOutFrames = frames;
    if (o->wireRate > o->sampleRate) {
        maxOutFrames = frames * (size_t) o->wireRate / (size_t) o->sampleRate + 2;
    }
    size_t wireCap = maxOutFrames * o->wireFrame;
    std::vector<uint8_t> wire(wireCap);
    size_t wireBytes = convertFrames(o, in.data(), frames * o->inFrame, wire.data(), wireCap);
    if (wireBytes == 0) return len; // 相位累积不足一输出帧，下次补齐
    if (!ringWrite(o, wire.data(), wireBytes)) return -1;
    return len;
}

extern "C" JNIEXPORT void JNICALL
Java_com_feiniu_usb_1audio_1exclusive_NativeUac_nativeStop(JNIEnv *, jclass, jlong handle) {
    auto *o = reinterpret_cast<UacOutput *>(handle);
    if (!o) return;
    o->running.store(false);
    pthread_mutex_lock(&o->ringMu);
    pthread_cond_broadcast(&o->ringCond);
    pthread_mutex_unlock(&o->ringMu);
    for (auto *urb : o->urbs) {
        if (urb) ioctl(o->fd, USBDEVFS_DISCARDURB, urb);
    }
    // join 必须恰好执行一次：reap 线程可能已自行退出（连续失败自杀），
    // 但线程资源仍需回收；用 joined 原子标记防止 double-join（UB）。
    if (!o->joined.exchange(true)) {
        pthread_join(o->reapThread, nullptr);
        if (o->fbThreadStarted) pthread_join(o->fbThread, nullptr);
    }
    // 安全网：DISCARDURB 后部分 URB 可能仍残留在 fd 完成队列（reap 线程已退出
    // 来不及回收）。排空它们，否则新会话 REAPURB 会捞到本会话 free 后的悬垂
    // 指针（dup fd 共享 dev_state 完成队列）→ use-after-free 堆损坏。
    for (int i = 0; i < NUM_URBS + 8; i++) {
        void *ptr = nullptr;
        if (ioctl(o->fd, USBDEVFS_REAPURBNDELAY, &ptr) < 0) break;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_feiniu_usb_1audio_1exclusive_NativeUac_nativeClose(JNIEnv *, jclass, jlong handle) {
    auto *o = reinterpret_cast<UacOutput *>(handle);
    if (!o) return;
    // 无论 running 与否都走 nativeStop：running=false 时 reap 线程可能还
    // 在退出途中（UAF 窗口），join 等它真正死透再释放（P0-1 加固）。
    Java_com_feiniu_usb_1audio_1exclusive_NativeUac_nativeStop(nullptr, jclass(), handle);
    for (auto *urb : o->urbs) free(urb);
    if (o->fd >= 0) close(o->fd);
    delete o;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_feiniu_usb_1audio_1exclusive_NativeUac_nativeUnderruns(JNIEnv *, jclass, jlong handle) {
    auto *o = reinterpret_cast<UacOutput *>(handle);
    return o ? (jint) o->underruns.load() : 0;
}
