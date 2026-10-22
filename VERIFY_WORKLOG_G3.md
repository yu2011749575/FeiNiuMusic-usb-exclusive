# 开源发布前自查：用户问题清单 → 修复状态（2026-09-25）

对照用户 P0/P1/P2 清单逐条核对代码，未解决项全部补完。**BUILD 通过（app-debug.apk，minSdk 26）**。

## P0 — 崩溃 Bug

### 1. use-after-free / SIGABRT ✅ 三层封死
- `shutdownPlayback` 调 `decoder.closeSink()`（已有）→ 本轮加固：
  - `ExclusiveDecoder.closed` 原子标记：closeSink/stop **先封写入口再释放 sink**，run() 循环写前检查 `closed||stopFlag`，杜绝 join(1500) 超时后残活线程的悬垂 `sink.write()`；
  - `stop()` join 超时 → `interrupt()` + 二次 join(500)；
  - C++ `nativeClose` **无条件走 nativeStop**（原来 running=false 时跳过 join → reap 线程未死透就 delete = UAF 窗口）；`joined` 原子标记保证 pthread_join 恰好执行一次（防 double-join UB）；
  - `nativeWrite` 入口 `running` 检查已有，且**语义修正**：停止时返回 -1（原来返回 0 会被 Kotlin 当成功→解码线程写进虚空）。
- 持续依赖既有防线：URB usercontext 所有权校验（drop stale URB）+ REAPURBNDELAY 排空安全网。

### 2. resubmit URB failed: 22 (EINVAL) ✅ 退避+自愈观察
- 指数退避：1ms→2→4→…→256ms 封顶（原固定 1ms）；EINVAL 为竞态瞬态，退避后通常自愈。
- REAPURB 遇 ENODEV/ESHUTDOWN/EIO（设备拔出）直接退出线程而非空转。
- P0-1 修完后 EINVAL 若仍出现，查 `planPacketBytes`：其按 `wireRate`（协商率）规划已核对无误（帧长=wireFrame×每包采样数，≤maxPacket 有钳制）。

## P1 — 通用性缺陷

### 3. 采样率固定 ✅ 协商+APP 内重采样+一次性提示
- `pickAlt` 重写为**协商式**（`Negotiation(alt, wireRate, exactRate)`）：
  源率在 DAC 支持列表 → wireRate=源率（bit-perfect）；不在 → 取最接近支持率。
- C++ 新增**线性插值重采样器**（rsPrev/rsFrac 跨调用保相位），`wireRate≠sampleRate` 时启用；44.1k→48k≈+9% 输出，缓冲按最坏情况分配。
- **提示**：协商发生重采样/降位时推 `notice` 事件 → Dart 弹对话框，**每 DAC 30 分钟一次**（用户要求"短时间只提示一次"）。
- 路由放宽：采样率不匹配不再拦出独占（重采样兜底后拦了反而绕远）。

### 4. 位深固定 ✅ 24/32bit + TPDF dither 降位
- 16/24/32bit 读写已全支持（loadSample32/storeSample 精确升位）。
- 原"禁止降位（无候选→放弃）"改为**dither 降位兜底**：无 ≥srcBits 的 alt 时选最大位深 alt，native 侧 TPDF 三角形 dither（±1 LSB）后截断——量化失真不集中成谐波。匹配位深时零 dither（保持 bit-perfect）。

### 5. 声道固定 ✅（上轮已完成，本轮复核）
- convertFrames 全声道组合映射：同数直通（bit-perfect）/ 上混复制 / 下混分组均值；AudioTrack 回退按声道数选 mask。

### 6. UAC1/UAC2 描述符容错 ✅ DeviceQuirks 机制
- 新增 `DeviceQuirks` 表（参考 Linux snd-usb-audio quirks 思路）：按 VID:PID 打补丁，
  支持 `forceUac2` / `ratesOverride`（率表损坏设备）/ `ignoreFeedback`（幽灵反馈端点）。
  新设备兼容问题加一行表即可，不动解析主逻辑。
- 既有容错保留：ECHO-A 精简 UAC2、HID 接口跳过、无静态率表（时钟编程型）判定。

## P2 — 稳定性与体验

### 7. 热插拔 ✅ 拔=优雅暂停，插回=断点自动恢复
- 播放中拔 DAC：shutdownPlayback + 关句柄 + 记断点（lastPlay+positionMs）+ emitState("paused")，**不崩**。
- 插回：600ms 后（等枚举）自动从断点续播；手动 stop 会取消自动恢复（resumePending 清除）。

### 8. 异常恢复 ✅ 指数退避+优雅降级
- URB 提交失败指数退避（见 #2）；连续 32 次失败 → reap 线程自杀 → nativeWrite 返 -1 →
  decoder 报 `error("usb write failed")` → 上层 fallback engines（系统输出），**不崩不卡死**。

## 技术约束核对
| 约束 | 状态 |
|---|---|
| 1. 原码输出优先 | ✅ 排序第一优先级=率精确匹配+位深充足（bit-perfect）；重采样/dither 仅兜底 |
| 2. 不破坏原有功能 | ✅ 全部改动限于 usb_audio_exclusive 插件+路由分支条件放宽；NAS 在线/下载/歌词/封面链路未动 |
| 3. 代码可维护 | ✅ C++ 全程中文注释（编译期 ASCII 日志除外）；Kotlin/Dart 接口清晰 |
| 4. 最低 Android 8.0 | ✅ minSdk 27→**26**；`setChannelIndexMask`(API28+) 加 SDK_INT>=28 守卫 |
| 5. 无 GPL 传染 | ✅ 全部自研代码，无 GPL 引入（可 Apache-2.0/MIT 发布） |

## 验证记录
- flutter analyze：0 error（新增 warning 已清，余为既有 lint）
- BUILD：`app-debug.apk` 成功（minSdk 26，100.9s）
- 真机回归（待手机回连）：G3 插拔压测 / 44.1k→48k 重采样弹窗 / 切歌压测 / 位深降位

## 修改文件（本轮）
- `usb_uac_output.cpp`：重采样器+dither+wireRate/srcBits 参数+nativeStop join 硬化+退避+write 语义
- `NativeUac.kt`：nativeStart 签名 +wireRate +srcBits
- `UsbDeviceFinder.kt`：协商式 pickAlt + DeviceQuirks + 接入 parse/start
- `ExclusiveDecoder.kt`：closed 守卫 + 写失败报 error（触发降级）
- `UsbAudioExclusivePlugin.kt`：热插拔暂停/恢复 + notice 推送 + lastPlay 断点
- `PcmSink.kt`：channelIndexMask API28 守卫 + catch 回退 mask 修正
- `usb_audio_exclusive.dart`：noticeEvents 流
- `usb_exclusive_service.dart`：notice 弹窗订阅
- `playback_router.dart` / `player_service.dart`：路由放宽（重采样兜底后不拦采样率）
- `android/app/build.gradle.kts` / `plugins/.../build.gradle`：minSdk 26

---

## 2026-09-25 夜轮：enc fix + 音量 + 压测脚本（本轮工作日志）

### 修复清单（全部 BUILD+装机+真机验证）
1. **enc fix（24bit 噪声根因）**：`ExclusiveDecoder.kt` — INFO_OUTPUT_FORMAT_CHANGED 捕获 outFormat（方案A）+ 首帧暂存相邻 pts 差实测 bytesPerFrame、不符以实测为准打 `enc fix: declared=X actual=Y`（方案B）+ 不可判定保守 16bit（方案C）+ seek flush 清 holdBuf。真机实锤 `enc fix: declared=21 actual=2 (frame 6->4)` → 自动选 16bit alt → 出声正常。
2. **音量键失效**：独占绕过 AudioFlinger → `PcmSink.kt` UacSink 软件增益（appVolume×sysVolume，双满格逐字节旁路=bit-perfect，否则逐采样线性斜坡防爆音，16/24/32bit/float 四分支）+ `UsbAudioExclusivePlugin.kt` volPoller 400ms 系统媒体音量轮询 + `ExclusiveDecoder.kt` setSystemVolume 转发。用户确认"音频声音可以正常使用"。
3. **采集武装一次性**：`usb_uac_output.cpp` capReset()（nativeStart 时关旧文件清计数重新武装 flag 检查）——原 g_cap.checked 每进程只查一次，脚本删旧文件后新会话写进已删 inode（症状=拉取空）。
4. **切歌恢复验证**：降级歌→无损歌自动恢复直出（logcat `resample=false`），无需手动干预。

### 压测脚本 workspace/dac_stress.py（~700 行）
- 三方交叉验证：DAC 能力（descriptor caps）× 协商声明（negotiate logcat）× 采集实测（in/out PCM）。
- 自动 UI 点歌（双向翻页+卡住检测）、布防采集、bit-perfect 比对（只允许插入不允许替换）、降级轮健康检查、报告 dac_stress_report.txt、换 DAC 回车续测、--analyze-only 离线分析。
- 内置：keep_awake/ensure_awake（防熄屏）、截图留档 shots/rN_{mid,end}.png + UI 异常字样检查、几何判定防静音误判（声明几何呈噪声才 FAIL，窗口自动选最大 RMS）。
- **冒烟结果**：1 轮 あのバンド 48k **PASS（bit-perfect：插入 0B 真失真 0B）**；几何 2B/采样 de=0.115 LR=0.606 与声明一致。

### 遗留（下一轮）
- 采集体量算术核对（in/out 3~5MB vs 名义 15s=2.8/2.9MB）。
- 21:02 轮 round2 `sink=audiotrack-fallback + 缺 negotiate` FAIL（kill 进程后设备状态残留或 G3 掉枚举）→ 干净复测。
- 桌面 GUI 抓取小工具（用户规格见 HANDOFF §5-1）。
- 44.1k 重采样回归、切歌/热插拔压测、50% 音量数值验证。

### 追加：小米15（Android 15/API35）USB 授权不弹窗修复
- **排查链**：无线调试配对（adb pair 43561/374281）→ logcat 实锤 `rescue-open: permission=false` → `startPlayback sink=audiotrack-fallback` 静默降级，system buffer 0 条 requestPermission → 设置页手动按"请求 USB 授权"按钮（无 catch）→ 露出真异常：
  `PlatformException: Targeting U+ (34+) disallows PendingIntent FLAG_MUTABLE + implicit Intent`。
- **根因**：`Intent(ACTION_PERMISSION)` 无 package=隐式，API34+ 禁止 FLAG_MUTABLE 配隐式 Intent；自动路径 `_autoRequestPermission` 的 `catch(_){}` 把异常吞掉 → 用户看不到任何弹窗。Android 12（Realme）不受此限制，故此前未暴露。
- **修复**：`UsbAudioExclusivePlugin.kt` 两处 PendingIntent（requestPermission 方法 L214 + openExclusive L435）改 `Intent(ACTION_PERMISSION).setPackage(context.packageName)`（显式化；必须保留 MUTABLE 才能收系统回填的 EXTRA_PERMISSION_GRANTED）；`usb_exclusive_service.dart` catch 改 debugPrint 可见日志。
- **验证**：装机→冷启动自动弹 `UsbPermissionActivity`→用户授权→再冷启动×2：`sink=usb_uac`、`negotiate resample=false dither=false`、`enc fix` 正常、requestPermission 0 次（不重复弹）。截图 xiaomi_final.png 视觉核对通过。

### 2026-09-25 小米15 二轮：16KB 对齐 + 卡顿诊断（结论标记暂缓）

- **16KB 页对齐**：用户报"7 个 so 未对齐"。新建 `workspace/check_16kb.py`（解包 APK 解析 ELF PT_LOAD p_align）实测：**只有我们自己的 libusb_uac_output.so align=4096 未对齐**，其余 6 个（libmpv/libflutter/libdartjni/libdatastore/libVkLayer/libmediakitandroidhelper）本就 16384/65536——列表是旧 APK 结果。修复：usb_audio_exclusive CMakeLists 加 `target_link_options(usb_uac_output PRIVATE "-Wl,-z,max-page-size=16384")`。复检 **0/7 未对齐**，装机成功。
- **卡顿诊断（用户裁定：标记暂不处理）**：先补 underrun 日志（ringRead 补零分支，限频首次+每50次，此前 nativeUnderruns 只计不读）→ 抓到实锤：
  1. 每次开播 600 次 underrun 补零爆发（≈600ms）+ 源曲前导 356ms = out 开播静音 1028ms（`analyze_silence.py`）→ 根因 nativeStart 初始填充在空 ring 上执行；
  2. 稳态 26.7s：0 underrun、0 静音段（重采样路径干净）→ **卡顿仅在开播/切歌瞬间**；
  3. 暂停不停 URB：pause 只置标志，reaper 补零 197.9s（out 涨到 43MB 全静音）；
  4. 偶发 30.5s stall ×2（冷启动首播、暂停恢复后）：startPlayback→negotiate 恰 30.5s，代码无 30s 常量，歌曲本地非网络，未定位。
  - 证据链+既定修法（预滚门/pauseStream+resumeStream/分段计时日志）已写入 HANDOFF.md §4 末"已知问题"档案；§5 头部挂"已标记暂缓"。
- **收尾**：HANDOFF/PROJECT_STATE 已回写；APK 副本刷新 `app-debug-fixed-20260925.apk` MD5=1fea67a8e20917db8abf08be9693477f（含 16KB+underrun 日志版）。

## 2026-09-25/26 ECHO-A 小尾巴爆音修复轮（小米15）

- **受理**：换 ECHO-A（VID=13058 PID=4805 UAC2/HS/adaptive 无 fb 端点）后部分音乐爆音（44.1k After the Battle 爆，48k 正常）。
- **23:44 轮（结构修复后首测）**：五处修复先上（native submitUrbRecover 端点自愈、decoder writeFailed 抑制 completed、引擎 _stopped 守卫、plugin lastSinkWasSystem 300ms settle、player_service 系统→usb 250ms settle）。结果：`startPlayback sink=usb_uac` 单会话、0 resubmit、0 降级、0 双会话——结构层互殴消失，但用户仍报爆音。
- **时钟归因探针**：`claim AudioControl iface=0 failed errno=16` + `GET_DESCRIPTOR device ok errno=0`（通路正常）+ `alt0 idle SET_CUR errno=16` → iface0 被另一个 usbfs fd 占；sysfs `1-1:1.0/1/2 -> NO_DRIVER`（无内核驱动绑定）→ 占者= audioserver USB audio HAL（播过系统 USB 音频后不放）；dumpsys AudioFlinger USB 线程 `localSR=47998.9` → DAC 实跑 48k 喂 44.1k = FIFO 周期性溢出欠载 = 爆音主因。
- **修复#1（时钟 wIndex hack）**：`uac2ClockCtrl` wIndex 低字节先试 acIface、EBUSY 换已 claim 的 streaming iface（固件取高字节 entity id）。日志实锤 `clock SET_CUR ok via stream iface=1 (acIf=0 rejected errno=16)` → `setSamplingFrequency(44100) ok attempt=0`。GET_CUR 经 stream iface 设备 STALL errno=32 EPIPE（仅诊断读回损失）。
- **修复#2-6（结构层，见 HANDOFF §4 第四项表格）**：端点自愈（ENOENT→重申自己的 alt→重投）、decoder 错误终止不补发 completed、引擎 stop 后丢弃迟到事件（幽灵 _playCurrent 杜绝）、系统通路→独占两处 ALSA settle 等待（300ms/250ms）。
- **终态日志（00:03 轮）**：SET_CUR ok attempt=0；UAC start rate=44100；稳态 0 underrun（600 包爆发全在开播同毫秒=已知补零）、0 resubmit、0 endpoint recovered、0 降级、activateLocked 全程 usbExclusive 单会话。
- **残留**：GET_CUR 读回不可用（EPIPE）；开播 600 包补零空隙（已知问题档案）；audioserver 可能再占（每次 startPlayback 重新 SET_CUR 覆盖）。
- **状态**：三文档已回写（HANDOFF §4 第四项 / PROJECT_STATE ⑤ / 本 worklog）。**终验（2026-09-26）**：①用户确认爆音消失；②bit-perfect 采集比对 PASS（见下节）。

## 2026-09-26 终验：爆音消失 + bit-perfect PASS（00:20 场，ECHO-A）

- **耳朵终验**：用户播放后确认"现在不爆音了"——爆音修复定案。
- **采集**：meta `rate=44100 ch=2 subframe=2 inEnc=2 wireFrame=4 hs=1 uac2=1`；bp_in.pcm 2516412B(14.27s) / bp_out.pcm 3519532B(19.95s)。期间用户按停一次（产生 6.2s 暂停空隙）。
- **比对**（analyze_bao 报"真失真 824628B"为**假阳性**——400KB 重同步窗盖不住 6.2s 暂停空隙；全窗口复核脚本 bp_verify.py + 尾段比对纠正）：
  - 开播预滚补零 87840B=498ms（已知问题，本次实测 <600ms）；
  - **段1 anchor→暂停点 1597440B（9.05s）：逐字节一致，0 插入 0 失真**；
  - 暂停切换：out 写 6.2s 补零（已知"暂停不停 URB"），in 侧解码超前 131072B 被丢弃（切换正常行为）；
  - **段2 重同步→尾 609848B（3.46s）：mismatch 0（0.000000%）**；
  - in 尾余 104324B = 停采集时序差（out 已关、in 多写 0.59s，未上线不可比，非缺陷）；
  - 播放期 0 静音空洞、削波 in/out 均 0%、咔哒>20000 两侧均 0。
- **结论**：**上线数据全部 bit-perfect（2,207,288B=12.51s 验证 0 失真），爆音修复+无损双终验通过**。
- 复核脚本：`workspace/bp_verify.py`（全窗口重同步 + 局部失配判真失真）。
