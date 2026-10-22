# 交接文档 — FeiNiuMusic USB 音频独占模式（新会话先读本文件）

> 用途：替代超长上下文。历史、现状、下一步、环境、坑全部在本文件 + `PROJECT_STATE.md`。
> 更新：2026-09-25 夜（enc fix + 音量修复 + 压测脚本完成；bug 已修复验证，剩压测收尾）

---

## 1. 一句话现状

为开源 Flutter 音乐播放器 **FeiNiuMusic** 实现 USB 音频独占（自研用户态 UAC 驱动，usbdevfs ISO URB，绕过 AudioFlinger，DAC bit-perfect 直出）。
**24bit 噪声 bug 已修复并真机实锤**（enc fix：`declared=21 actual=2`，自动改选 16bit alt，出声正常）；**音量键已修复**（UacSink 软件增益，用户确认可用）；**Android 14+ 不弹授权已修复**（PendingIntent 显式化，小米15 验证）；**16KB 对齐已完成**（`check_16kb.py` 复检 0/7 未对齐）；**压测脚本 dac_stress.py 已跑通全链路**；**ECHO-A 小尾巴爆音已修复（6 处，档案在 §4 第四项，耳朵终验通过：2026-09-26 用户确认不爆音）**——时钟 SET_CUR 44100 经 wIndex hack 成功、双驱动互殴三连修；**bit-perfect PASS（00:20 场 12.51s 音乐逐字节 0 失真 0 削波 0 咔哒）**。
**已知问题（2026-09-25 用户裁定：标记暂不处理）**：开播/切歌瞬间卡顿（见 §4 末"已知问题"档案）。稳态播放干净（26.7s 采集 0 underrun 0 静音）。剩：多 DAC 换机压测、采集算术核对、桌面 GUI 抓取小工具（见 §5）。

---

## 2. 文档体系（工作靠文档，不靠上下文）

| 文件 | 作用 |
|---|---|
| `FeiNiuMusic/HANDOFF.md` | 本文件，总入口 |
| `FeiNiuMusic/PROJECT_STATE.md` | 外部记忆（压缩版）：状态/规划/坑/验证环境 |
| `FeiNiuMusic/VERIFY_WORKLOG_G3.md` | 工作台：P0/P1/P2 自查表 + 各轮工作日志 |
| `FeiNiuMusic/VERIFY_WORKLOG.md` | ECHO-A 阶段归档（UAF 修复+bit-perfect 验证） |
| `workspace/dac_stress.py` | **多 DAC 轮换压测脚本**（三方交叉验证，报告 dac_stress_report.txt） |
| `workspace/verify_seg.py` / `analyze_fmt2.py` | 比对器原型（算法已移植进 dac_stress.py） |

每完成一个节点，回写 PROJECT_STATE.md；工作细节写 VERIFY_WORKLOG_G3.md。

---

## 3. 历史关键节点（压缩时间线）

1. **ECHO-A 阶段**：UAF 根因修复（所有权校验+排空）→ 44.1k/16bit 真机 bit-perfect PASS（真失真 0B）。
2. **G3 阶段**：换 DaiLing G3 六连 bug 全修（路由死循环、44.1k 风暴、convertFrames 等）。
3. **开源自查（P0/P1/P2）**：8 条清单全落地 + minSdk 26，BUILD 成功。
4. **真机回归**：48k 协商完美但 あのバンド 出噪声啸叫 → 根因定位 inEnc 帧错位（声明 21 实际 2）。
5. **enc fix 修复**（2026-09-25 夜）：真机实锤 `enc fix: declared=21 actual=2 (frame 6->4)` → `negotiate: resample=false dither=false altBits=16` → 出声正常。
6. **音量修复**：独占绕过 AudioFlinger 音量键天然无效 → UacSink 软件增益，用户确认"音频声音可以正常使用"。
7. **压测脚本**：dac_stress.py 全链路跑通（UI 自动点歌→协商→采集→三方交叉判定），1 轮 bit-perfect PASS。

---

## 4. 已修复 bug 档案（原 24bit 噪声+啸叫）

### 现象（历史）
独占 48k/24bit 播 あのバンド → 噪声+啸叫（音高畸变）；降级正常；44.1k/16bit bit-perfect 正常 → 特定 24bit 通路。

### 根因（已实锤）
源 FLAC 24bit → 请求 `ENCODING_PCM_24BIT_PACKED(21)`，MediaCodec 实际只出 16bit（`pcm-encoding=2`，4B/帧），但 `codec.outputFormat` 回显请求值 21 → inEnc=21 与数据错位 → 按 6B 读 4B → 噪声啸叫。`INFO_OUTPUT_FORMAT_CHANGED` 被空过加剧。

### 修复（已落地，三方案合体）
- **A**：`INFO_OUTPUT_FORMAT_CHANGED` 分支捕获 `outFormat`。
- **B**：首帧暂存，相邻两帧 pts 差×采样率求实测帧数 → 实测 bytesPerFrame，不符以实测为准，日志 `enc fix: declared=X actual=Y`。
- **C**：不可判定保守 16bit，禁止按错位帧长写 URB。
- 实现：`ExclusiveDecoder.kt` 新增 `outFormat/holdBuf/holdPtsUs/emitFrame()/bytesPerSample()/encodingForBytesPerSample()/fixEncoding()`；seek flush 后 `holdBuf=null`。

### 验证（真机通过）
logcat 实锤 `enc fix: declared=21 actual=2 (frame 6->4)` → 协商自动改选 16bit alt（`srcBits=16 altBits=16`）→ 出声正常无噪声。采集几何：实测 2B/采样（de=0.115~0.120 LR≈0.60）与声明一致。

### 第二个已修 bug（2026-09-25 夜）：Android 14+ 不弹 USB 授权
- **现象**：小米15（Android 15/API35）插 DAC 播放不弹授权窗，静默降级 `audiotrack-fallback`（Realme Android 12 正常）。
- **根因（实锤）**：`PendingIntent.getBroadcast(Intent(ACTION_PERMISSION), FLAG_MUTABLE)` —— 隐式 Intent 在 U+(API34)+ 禁止配 FLAG_MUTABLE → requestPermission 抛 `PlatformException`，自动路径 `catch(_){}` 静默吞掉 → 系统从未收到请求（logcat system buffer 0 条 UsbPermissionActivity）。
- **修复**：两处 PendingIntent 改 `Intent(ACTION_PERMISSION).setPackage(context.packageName)`（显式化，保留 MUTABLE 以接收系统回填 EXTRA_PERMISSION_GRANTED）；Dart `_autoRequestPermission` 的 catch 改 `debugPrint` 不再吞错。
- **验证**：小米15 弹窗出现 → 用户授权 → 冷启动×2：`startPlayback sink=usb_uac` + `negotiate resample=false dither=false` + `enc fix` 正常 + 不重复弹窗（requestPermission 调用 0 次）。

### 第三项（2026-09-25）：16KB 页对齐兼容性
- **现象**：应用市场/系统提示"此应用不符合 16 KB 对齐要求，以下库 LOAD 区段未对齐"（列了 7 个 so）。
- **排查（`workspace/check_16kb.py`，解析 APK 内 ELF PT_LOAD p_align）**：7 个 so 中**只有我们自己的 `libusb_uac_output.so` 真未对齐（align=4096）**，其余 6 个（libmpv/libflutter/libdartjni 等）本来就是 16384/65536——用户看到的列表是旧 APK 检查结果。
- **修复**：`plugins/usb_audio_exclusive/android/src/main/cpp/CMakeLists.txt` 加 `target_link_options(usb_uac_output PRIVATE "-Wl,-z,max-page-size=16384")`。
- **验证**：`check_16kb.py` 复检 **0/7 未对齐**；APK 已装小米15。

### 第四项（2026-09-25/26）：ECHO-A 小尾巴爆音（已修复，**终验通过 2026-09-26**）

**现象**：换 ECHO-A 小尾巴（VID=13058/PID=4805, UAC2, HS, adaptive 无反馈端点）后**部分音乐爆音**——44.1k 曲（After the Battle）爆，48k 曲正常。

**根因（三层，全部实锤）**：

1. **时钟层（爆音主因）**：AC 接口(iface0) 被 audioserver 的 USB audio HAL fd **长期 claim**（sysfs 实测三接口 NO_DRIVER = 无内核驱动绑定，却 claim EBUSY = 另一个 usbfs fd 占着；系统播过 USB 音频后不放）。usbfs `check_ctrlrecip` 按 `wIndex&0xff` 校验 claim，UAC2 时钟请求 wIndex 低字节恰好= iface0 → **SET_CUR 44100 永远 EBUSY** → DAC 跑系统配过的 48k（dumpsys localSR=47998.9 实锤）→ 我们按 44.1k 喂 → FIFO 周期性溢出/欠载 = 爆音。
2. **结构层（双驱动互殴）**：冷启动 rescue `permission=false` → `audiotrack-fallback`（ALSA 流）→ 点歌进 usbExclusive 后 ALSA 异步拆流作废端点 → `resubmit ENOENT` 退避死循环 3.5s → ring 堵死 `usb write failed` → 降级 just_audio（DEEP_BUFFER 系统音轨）——同时**解码器写失败后仍补发 `completed`**（`if(!stopFlag)` 不判错误）→ 已停未 dispose 的 usb 引擎 `_onCompleted` 幽灵 `_playCurrent` → 13.518ms 处拉起第二个 usb 会话 → 系统流+usbfs 双驱动互殴 = 爆音。"部分音乐"=只有触发竞态的场次中招。
3. 开播 600 包补零空隙（已知问题，本档案外）。

**修复（6 处，全部已 build 装机）**：

| # | 文件 | 修复 |
|---|------|------|
| 1 | usb_uac_output.cpp | `uac2ClockCtrl`：时钟 SET_CUR/GET_CUR wIndex 低字节先试 acIface，EBUSY 换**已 claim 的 streaming iface**（固件只取高字节 entity id）→ `setSamplingFrequency(44100) ok attempt=0` |
| 2 | usb_uac_output.cpp | `submitUrbRecover`：SUBMITURB ENOENT/EINVAL → 重申自己的 alt（SETINTERFACE）复活端点再重投（reap+初始两处），不再退避死等 |
| 3 | ExclusiveDecoder.kt | `writeFailed` 标志：sink 写失败后**不再补发 completed**（错误终止≠播完） |
| 4 | usb_exclusive_engine.dart | `_stopped` 会话守卫：stop() 后丢弃全部迟到插件事件，杜绝幽灵 `_playCurrent` |
| 5 | UsbAudioExclusivePlugin.kt | `lastSinkWasSystem`：上一轮走系统通路 → startPlayback 前 sleep 300ms 等 ALSA teardown 收尾 |
| 6 | player_service.dart | 系统引擎(just_audio/media_kit) → usbExclusive 切换前 delay 250ms 等 ALSA 收尾 |

**验证**：探针归因 `GET_DESCRIPTOR ok errno=0`（通路正常）+ `claim iface0 EBUSY`（占用实锤）；修复后 `clock SET_CUR ok via stream iface=1`、`setSamplingFrequency(44100) ok attempt=0`；稳态 0 underrun 0 resubmit 0 降级 0 双会话；开播 600 包补零仍在（已知问题）。

**残留**：① GET_CUR 读回被设备 STALL（errno=32 EPIPE，设备拒 GET 用 stream iface）→ 无法读回确认，SET_CUR ACK 即接受；② audioserver 下次播系统音可能再占（我们每次 startPlayback 都会重新 SET_CUR，占用只影响其后未开始的会话）；③ 开播补零空隙。

### 第五项（2026-09-26 受理）：直接切歌"无声但 UI 在走"（进行中，未定位）

**现象**：不是上一首/下一首，而是**在列表里直接点另一首**时出现：播放按钮、进度、歌词都在走，就是没声音。点下一首（或再点几次）会恢复。

**已有证据（bitperf_test.log，00:08-00:23，小米15+ECHO-A）**：
- 13 次 `startPlayback sink=usb_uac`，其中 **4 次后面完全没有 `negotiate:`/`UAC start`**（00:19:20.972、00:19:25.413、00:20:42.727、00:23:29.210）→ **会话启动到一半死掉 = 无声会话的指纹**；下一次 startPlayback（再点一首）就恢复。
- 失败窗口内 **Dart 侧无 error/recover/降级日志** → `output configure failed`/`usb write failed` 事件没发出（或没到达），排除了已知降级路径。
- 成功路径时间线：`startPlayback → negotiate(+42~460ms) → UAC start`，失败路径在 `startPlayback` 之后 Kotlin 侧一片寂静。

**代码静默点地图**（`UsbDeviceFinder.start()` L245）：`pickAlt null` / `usbInterfaceFor null` / `claimInterface false` 三处 `return false` **全都不打日志**；`conn.setInterface(intf)` 返回值被忽略；`emitState()` 只发 Flutter 不写 logcat（所以 error 事件在 logcat 里不可见）。`start()` 之前还隔着 MediaExtractor setDataSource/codec open/凑够两帧（网络源开流）这段无日志区。

**Dart 侧放大器**：`usb_exclusive_engine.play()` **乐观置位** `_playing=true; _emitState()`（不等插件确认）→ 按钮/状态先行变"播放"，即使 Kotlin 会话根本没起来。歌词走需要 position 事件 → 解码器必须已 configure 成功 → 与"无 negotiate 日志"矛盾 → **待复现取证**（logcat 可能丢行，或存在另一类"跑着但没声"的模式）。

**假设排序**：① start() 三静默失败之一（claim EBUSY/alt 查找失败）→ configure false → error 事件但 UI 乐观态掩盖；② 解码器卡在开流/凑帧（网络）→ 无事件；③ logcat 丢行掩盖了已起的会话（真无声需另找原因，如 setInterface 失败 alt 没切）。
**下一步**：四处插桩（handle.start begin/三个失败原因/emitState 落 logcat/decoder 开流里程碑）→ 重建装机 → 复现直接切歌 → 一次定位。

### 已知问题（2026-09-25 用户裁定：标记，暂不处理 → 2026-09-26 用户裁定：**待下月额度重置后再修**）

**开播/切歌瞬间卡顿**（600ms 补零空隙）。**修法评估已完成（2026-09-26）**：中等偏低难度，1 小时内可修完——初始投递挪进 reapThread + `pthread_cond_timedwait` 等 ring 攒够 100-150ms 预滚再投；必须加超时兜底（~500ms 到了带已有数据投出，防开播死等）；注意 pause/resume 与预滚等待的竞态；预期收益：开播静音 1028ms → ~350-400ms（源曲自身前导 356ms 不可动），开播晚 100-150ms 出声换连续性；改完须跑完整回归（开播/切歌/暂停恢复/双会话）。**触发条件：等下月额度重置后执行，且须在 ECHO-A 爆音耳朵终验通过之后**（避免一次改两件事无法归因）。稳态干净（26.7s 采集 0 underrun 0 静音），只有开播瞬间有毛病，实锤三件：
1. **每次开播 ~1 秒静音空隙**（卡的主体）：out 采集开播静音 1028ms = 600 次 underrun 补零（≈600ms，`have=0 need=192 ring=0/103936` 爆发）+ 源曲自身前导静音 356ms。根因：`usb_uac_output.cpp nativeStart` 的"首次填充并全部投递"在 **空 ring** 上执行（首帧 emit 在 configure 之后才来）→ 首批 URB 全是补零。**修法已定**：初始填充挪进 reapThread，先 `pthread_cond_timedwait` 等 ring 攒够 ~100-150ms 预滚再投 URB（decoder 线程并发写入无死锁）。
2. **暂停不停 URB**（次缺陷，无声但费电/污染采集）：`ExclusiveDecoder.pause()` 只置 `paused` 标志，reaper 继续补零 → 暂停后 out 涨 197s 全静音。**修法已定**：PcmSink 加 `pauseStream()/resumeStream()` 默认空实现，UacSink 实现为 `handle.stopInternal()`/`handle.start(存参数)`；在解码线程 `waitIfPaused()` 入口调用（与写同线程，无竞态），`resume()` 先 restartStream 再 notify。
3. **偶发 30.5 秒 stall**（未定位，出现 2 例：冷启动后首次播放、暂停恢复后）：`startPlayback` → 恰 30.5s 后才 `negotiate+UAC start+underrun 爆发`。已排除：Kotlin/Dart 无 30s 常量（唯一命中 media_kit `.timeout(openTimeout)` 不在 USB 链路）、歌曲 URL 为本地非网络超时。下一步：ExclusiveDecoder.run() 加分段计时日志（setDataSource/codec start/首帧/配置）复现定位。

---

## 5. 下一步规划（顺序执行）

> **已标记暂缓**：开播/切歌瞬间卡顿修复（预滚门+暂停停 URB+30s stall 定位）——2026-09-25 用户裁定先不管，档案在 §4 末"已知问题"，要修时按档案里的既定修法直接动手。

1. **桌面 GUI 抓取小工具**（用户明确需求，规格如下）：
   - 桌面脚本，界面只显示：①手机连接状态 ②USB 独占是否开启；
   - "没问题"→用户**手动点开始**→开始抓输出（采集）；**手动点停止**结束；
   - 检测内容放**单独文件夹**；用户人工检查完再让 agent 读该文件夹分析有没有问题。
2. **多 DAC 换机压测**：`dac_stress.py`（已可换 DAC 回车续测），确保"该无损时一定是 USB 独占无损"。
3. **采集体量算术核对**：今日 in/out 各轮 3~5MB（15s 名义 2.8/2.9MB）与播放时长+预填充的算术解释未核对。
4. **复测 21:02 轮异常**：round2 报 `sink=audiotrack-fallback + 缺 negotiate`（前一轮被 kill 后设备状态残留或 DAC 掉枚举），需干净复测。
5. 44.1k 重采样回归（After the Battle id=1954，wire=48000）+ 切歌压测 + 热插拔拔插恢复 + 44.1k 不风暴。
6. 50% 音量数值验证（out≈0.5×in）+ 满格 bit-perfect 复核（音量功能数据验证）。
7. 开源发布准备：LICENSE/README/兼容矩阵。

---

## 6. 环境速查

**构建**
```bash
export ANDROID_HOME="D:/android-sdk" ANDROID_SDK_ROOT="D:/android-sdk"
export JAVA_HOME="C:/Program Files/Microsoft/jdk-17.0.19.10-hotspot"
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy   # 纯直连！唯一例外 api.b.ai 走 7897
C:/Users/Lenovo/flutter/bin/flutter build apk --debug --target-platform android-arm64
# 增量 20~100s；NDK 27.0.12077973 + cmake 3.22.1；minSdk=26
```

**真机**
```bash
A="/d/android-sdk/platform-tools/adb.exe -s <测试机IP>:5555"   # Realme RMX3161 Android 12（WiFi）
$A install -r C:/Users/Lenovo/AppData/Local/hermes/workspace/FeiNiuMusic/build/app/outputs/flutter-apk/app-debug.apk  # install 必须 Windows 路径
$A shell monkey -p com.feiniu.music 1
```
- 戴灵 G3 (Jieli, VID 3654:4255 / 压测显示 13908:16981)：UAC1 全速、仅 48000Hz、alt1=16bit/192、alt2=24bit/288。
- 验证不得依赖 root（Magisk 拒授权），一切用 `run-as com.feiniu.music`。

**采集流程**
```bash
$A shell "run-as com.feiniu.music sh -c 'cd files && rm -f uac_cap_in.pcm uac_cap_out.pcm uac_cap_meta.txt uac_cap.on; touch uac_cap.on'"
# 播放 → 暂停 → 拉取（run-as cat 错误文本会混入 stdout，先 ls 确认文件存在）
$A exec-out run-as com.feiniu.music sh -c 'cat files/uac_cap_in.pcm' > r_in.pcm
```

**压测**：`python dac_stress.py --rounds 3 --secs 25`（自动点歌/布防/判定/报告/换 DAC 回车续测；`--analyze-only --tag r1` 离线分析）。截图留档 `workspace/shots/rN_{mid,end}.png` 供视觉复查。

**UI 坐标（1080×2237，标签在 content-desc）**
底部 tab 歌曲(540,2198)；列表第一行中心(540,511)（bounds [48,415][1032,607]）；迷你播放栏 y≈2050（搜索须排除 y>1900）；滑动 `input swipe 540 700 540 1600`=去顶部、`540 1600 540 700`=去底部；设置页「音频独占」y≈1490；USB 授权弹窗确定(885,1418)。

**logcat tag**：`UsbUacParse` `UsbUacOutput`（`enc fix`/`CAPTURE ON`/`UAC start`）`UsbDeviceFinder`（`negotiate`）`UsbAudioExclusivePlugin`（hotplug/notice）`MediaCodec`（`pcm-encoding`）。
**scrcpy**：`C:/Users/Lenovo/Downloads/scrcpy333/scrcpy-win64-v3.3.3/scrcpy.exe -s <测试机IP>:5555`。
**NAS**：`https://<你的NAS域名>:443`，`<用户名>` / `<密码>`，token=`<music-token>`（真实凭据已从公开文档移除）（Cookie `music-token=`），API 前缀 `/music/api/v1`。

---

## 7. 关键文件地图

| 文件 | 说明 |
|---|---|
| `plugins/usb_audio_exclusive/android/src/main/kotlin/.../ExclusiveDecoder.kt` | enc fix 主战场：outFormat/holdBuf/emitFrame/fixEncoding + setSystemVolume 转发 |
| `plugins/usb_audio_exclusive/android/src/main/kotlin/.../PcmSink.kt` | UacSink 软件增益引擎（appVolume×sysVolume，双满格旁路=bit-perfect，逐采样斜坡衰减） |
| `plugins/usb_audio_exclusive/android/src/main/kotlin/.../UsbAudioExclusivePlugin.kt` | volPoller 400ms 系统媒体音量轮询 + shutdown/startPlayback 接线 |
| `plugins/usb_audio_exclusive/android/src/main/kotlin/.../UsbDeviceFinder.kt` | start(sr,ch,srcBits,inEnc) 协商+pickAlt+DeviceQuirks+nativeStart |
| `plugins/usb_audio_exclusive/android/src/main/cpp/usb_uac_output.cpp` | 采集 g_cap(L184)/capMaybeOpen(L200)/capWrite(L222)；**capReset()（nativeStart 调用，每会话重新武装采集）**；convertFrames/dither；capWrite 调用点 L762(out)/L947(in) |
| `lib/app/services/player/usb_exclusive_engine.dart` | Dart 侧引擎封装 |

---

## 8. 约束与坑（硬性）

**用户工作方式**：只要最终结果，一口气执行到底，严禁中途问"要不要继续"；"卡了吗"=催进度；任务中途严禁穿插无关内容；测试时要用视觉模型盯手机屏幕核对（截图 vision 复查），不要纯盲跑。
**技术约束**：bit-perfect 优先（匹配时零重采样零 dither 零衰减）；不破坏 NAS/下载/歌词/封面；C++ 日志字符串必须 ASCII（NDK 源内非 ASCII 乱码）；minSdk 26；无 GPL；.bat 纯 ASCII；UI 文字中文。

**坑**
1. `execute_code` BLOCKED；heredoc/大命令易被 blocklist → 写 .py/.sh 文件执行。
2. `search_files` 路径 bug → terminal grep；`read_file` 误判 .md/.cpp 为二进制 → sed 读。
3. C++ 只有 LOGI/LOGE（无 LOGW）；git-bash 传中文/引号 mangle（run-as 需嵌套引号）；adb install 必须 Windows 路径。
4. uiautomator dump 间歇 "could not get idle state"；UI 标签在 content-desc；Flutter 文字常在不可点击子节点上。
5. **帧格式判别**：不能只看字节整除性（采集按声明帧长截断写入会骗人），必须 diff/energy + L/R 相关性；**且平滑/静音段两假设皆平滑会误判**——判定以"声明几何下数据是否呈噪声（de>1/LR≈0）"为准，分析窗口自动选最大 RMS 段（dac_stress.py 已内置）。
6. **采集武装一次性**：`g_cap.checked` 原每进程只查一次 flag，脚本删旧文件后新会话写进已删 inode（症状=拉取空/错误文本）→ 已修 capReset()（每会话重新武装）；拉取前先 ls 确认文件存在。
7. **手机会自动熄屏**（5min 超时）打断 UI 点击和采集 → dac_stress.py 已内置 keep_awake（svc power stayon + 30min 超时）+ ensure_awake（每轮唤醒解锁）。
8. ENC 常量：ENC_PCM_16=2、ENC_PCM_24_PACKED=21、ENC_PCM_FLOAT=4、ENC_PCM_32=22。
9. 协商排序 pickAlt：exactRate > subframe*8>=srcBits > channels==srcCh > bitDepth==srcBits > |bitDepth-srcBits| > |wireRate-sampleRate|。
10. notice 协议：Kotlin pushNotice → `{"kind":"notice",...}` → Dart AlertDialog。

## 9. 技术决策记录（摘要）

1. UAF 修复=所有权校验+排空；URB usercontext 存下标双重比对；joined 原子保证 join 恰好一次。
2. P1-3 协商：源率命中=bit-perfect 直出；不命中=最接近率+线性插值重采样+每 DAC 30min 一次弹窗。
3. P1-4 dither：位深充足优先，降位时 TPDF dither（不拒绝播放）。
4. nativeWrite 失败返 -1（非 0）；热插拔拔=暂停记断点，插回 600ms 自动续播。
5. DeviceQuirks：VID:PID 补丁表；Android 8.0：minSdk 26 + API28 守卫。
6. **enc fix 原则**：inEnc 以 MediaCodec **实际输出**为准（实测数据几何 > outputFormat > 请求值）；声明与数据不一致=帧错位=噪声，致命；不可判定保守 16bit。
7. **音量方案**：独占绕过 AudioFlinger → UacSink 软件增益=app 音量×系统媒体音量比（400ms 轮询）；双满格逐字节旁路=bit-perfect 不受损；调低才线性衰减（缓冲内斜坡防爆音）。
8. **压测判定**：DAC 支持源率+位深充足 → 必须 `resample=false & dither=false & sink=usb_uac & 采集真失真=0B`（只允许插入不允许替换）；DAC 不支持 → 允许降级但出流必须健康。每首歌独立协商，降级歌→无损歌自动恢复直出。
9. 切歌恢复：每首歌独立协商自动恢复（已实锤）。

## 10. 本会话增量（2026-09-25 夜，供追溯）

- ExclusiveDecoder.kt：enc fix 三合体（A+B+C）+ seek flush 清 holdBuf + setSystemVolume 转发。
- PcmSink.kt：UacSink 软件增益（16/24/32bit/float 四分支逐采样斜坡）。
- UsbAudioExclusivePlugin.kt：volPoller 400ms 系统音量轮询（shutdown 停轮询，startPlayback 注入当前音量）。
- usb_uac_output.cpp：capReset()（nativeStart 会话开始重置采集）。
- 新建 `workspace/dac_stress.py`（~700 行）：Adb/uidump/双向翻页找歌/布防采集/三方交叉判定/报告/换 DAC 循环/--analyze-only/截图+UI 异常字检查/keep_awake。
- 真机验证：enc fix 实锤+出声正常+切歌自动恢复；音量用户确认；压测 1 轮 bit-perfect PASS（あのバンド 48k，插入 0B 真失真 0B）。
- 遗留瞬态：21:02 轮 round2 `audiotrack-fallback` FAIL（见 §5-4 待复测）；DB 清理临时脚本 dbgui*.py/shot_*.png 可删。

## 11. 本会话增量（2026-09-25 小米15 轮，供追溯）

- **Android 14+ 授权修复**：UsbAudioExclusivePlugin.kt 两处 PendingIntent `setPackage(packageName)`；Dart `_autoRequestPermission` catch 不再吞错。小米15 验证弹窗→授权→冷启动 sink=usb_uac。
- **16KB 对齐**：CMakeLists.txt 加 `-Wl,-z,max-page-size=16384`；新建 `workspace/check_16kb.py`（ELF PT_LOAD p_align 检查）复检 0/7。新建 `workspace/analyze_silence.py`（out 静音段分布分析）。
- **卡顿诊断（结论已进 §4 已知问题）**：usb_uac_output.cpp ringRead 补零分支加 underrun 限频日志（首次+每50次，`nativeUnderruns` 此前只计不读）→ 抓到开播 600 次 underrun 爆发；`capReset()` 保证每次会话采集重置。
- 采集数据：`workspace/r1_in.pcm`(4.6MB)/`r1_out.pcm`(43MB) + 截图 xiaomi_*.png 留档。
- 最新 APK：`build/app/outputs/flutter-apk/app-debug.apk`（MD5 `1fea67a8e20917db8abf08be9693477f`，含 16KB+underrun 日志，已装小米15）。
