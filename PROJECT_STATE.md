# 飞牛音乐（FeiNiuMusic）项目状态文档

> **用途**：本项目"外部记忆"。一切进度、结论、下一步**以本文档为准**，不依赖对话上下文。
> **交接入口**：`HANDOFF.md`（新会话先读它——历史节点/当前 bug 证据链/下一步规划/环境速查/坑全在里面）。
>
> **2026-09-26 人声分离/结像四因排查档案⑧（外部烧友意见逐项验证：②①排除、③头号嫌疑、④特性）**：
> 背景：用户听感"独占人声分离不强、声场压缩"，外部意见列4嫌疑（URB抖动/通道位宽/响度/DAC滤波）逐项查证：
> **1. 通道/位宽映射 → 实测排除**：uac_cap 采集点=打包前(nativeWrite)与装填后(fillUrb)，bp3 逐字节一致 2,744,698B=打包链无任何改写（含声道顺序）；storeSample 2/3/4 字节 LE 全对、声道映射 1:1 直通无交换、loadSample32 升位精确；实测 L/R 能量对等(13073/13048)。24bit 路径仅代码审读正确（ECHO-A 协商16bit 未实测）→ 遇 24bit DAC 必复跑 bp_verify。
> **2. URB 时序抖动 → 架构排除**：USBDEVFS_URB_ISO_ASAP + NUM_URBS=80 深管线（decent-player 处方）+ 阻塞 REAPURB（DAC 时钟背压）+ ASYNC FB 反馈线程(HS16.16/FS10.14) = 包到达抖动由内核调度+DAC 内部 FIFO 吸收，重建时钟=DAC 晶振，不改 L/R 相位（L/R 恒同包顺序递交）。ring=100816B≈0.57s。真·断供=underrun：稳态 0 次，仅开歌空窗自愈突发（06:04:37 实例 1s 内恢复）。
> **3. 响度/音效链 → 头号嫌疑（待用户 ABX）**：独占旁路 AudioFlinger=连 MIUI 音效（音质音效/杜比/Mi Sound）一并旁路，普通模式有系统 EQ 抬中频；独占软件增益=appVolume×sysVolume 单标量、L=R 同值（PcmSink L68）不毁结像。验证：关"音质音效"再听普通模式 / 同响度 ABX。
> **4. DAC 重建滤波 → 特性非 bug**：普通模式 AudioFlinger 混音多跑 48k（SRC 参与调音），独占=44.1k 原生直出，滤波风格差异=烧友常见"开独占反而收敛"。交叉换 2-3 款小尾巴验证。
> **疑点待查**：bp3_out L/R 零相关(corr=0.008，±2000lag 无峰)——主流人声居中混音应 0.5+；先识别 02:51 那首（本身宽混音/karaoke 分体则无罪），下步同曲目普通模式对录比 corr。附带：06:05:40 app binderDied 第5次进程死亡(crash buffer 空)；adb mDNS 掉线。

> **2026-09-26 后台不保活档案⑦（根因定案+修复）**：
> - 现象：切微信后台 ~1min 后没声，通知栏进度条还在跑。
> - 根因（04:42 实锤）：audio_service FGS `isForeground=true` 正常，但 **MIUI 按省电策略"智能限制后台运行"在切后台 ~45s 冻结整个进程**（Kotlin 解码日志+native 泵同时静默；`dumpsys media_session` PlaybackState.position 定格 32415 不更新=Dart 也停；通知栏进度靠系统外推"假跑"）。同刻 MiuiAudioPlaybackManager 在焦点丢失+46s 处疯刷规则日志。
> - 修复（audio_service FAQ 标准处方）：manifest 补 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`；新增 `lib/app/services/battery_guard.dart` 首次激活播放一次性弹窗（幂等 prefs `battery_exempt_prompted`），挂 `_activateLogicalIndexLocked` + `play()`；`Permission.ignoreBatteryOptimizations.request()` 在小米直接落到 MIUI 省电策略页→选"无限制"→`deviceidle whitelist` 已含 `user,com.feiniu.music`。
> - 排查盲点（下次别再踩）：①Flutter AlertDialog 按钮在 uiautomator dump 里是 `content-desc` 不是 `text` ②bg_repro.log 采集 pattern 要含被查 tag（BatteryGuard 曾被滤掉）③`logcat -t 300` 会被 MIUI 刷屏吃光，用流式采集文件。
> - **seek 回开头（已修·2026-09-26 终审）**：根因=**`MediaExtractor.seekTo()` 参数是微秒，代码传了毫秒**（÷1000：实锤 seek 248544ms 落 0.248s、86820ms 落 0.087s、随后读帧从 1.985s 线性推进=永远回开头重播）。原版 ExoPlayer 传 µs 所以没事。**修①**`seekTo(seek*1000L)`（feed 循环）+ `startMs*1000L`（CUE 开播同病）。**修②**同处新增 `lastReport=0`——后退 seek 后 pos-lastReport 为负，`>=250` 判定永久不成立→进度停报。**验证 PASS**：前进 seek 204521ms→sampleTime=204521000us 精准、后退 224126→37220ms→37220000us 精准、state= 进度均连续（05:51:22/05:51:42 实测）。探针：plugin `seek ms=`、decoder `seekTo target/sampleTime`、engine `[UsbExclusiveEngine] seek`、seekdbg 20轮。audio_focus：后台会被抖音抢焦点，keep-alive 25s 会重新拿回。**遗留疑云：进程无声重启×4（18448/25652→27901 等，crash buffer 空、非 Java 崩溃，待查）**。
>
> **2026-09-26 无声 bug 档案⑥（进行中→已修3层）**：
> - 现象：列表（歌曲/歌单页）点切歌没声，播放页内切正常；原版无此问题。
> - 根因1（已修）：isFile=false 网络歌 `MediaExtractor.setDataSource` 固定 30.46s 超时重试（4次实锤）→ 切歌即哑30s。修=开流前 HttpURLConnection 预热（4s上限），warm 后开流 0.95s。`ExclusiveDecoder.kt` preflight。
> - 根因2（已修）：列表点触双触发/连点 → playQueue 连发两次（01:43:53 gen7→gen8 双开流互踩）+ 队列填充 re-activate（run=[0,99]→[0,147]→[0,195]）。修=playQueue 800ms 同键去抖（player_service.dart）。
> - 根因3（已修）：USB 设备掉线恢复窗口：attach+0.58s 单次补开必失败→跌落 audiotrack-fallback 扬声器=DAC 没声（01:43:32 实锤）。修=rescue-open 重试 5×600ms + usbWasActive 守卫（UsbAudioExclusivePlugin.kt）。
> - 遗留：-108 ESHUTDOWN 两次（01:43:25 真掉总线6.3s=疑似小尾巴接触/供电；01:55:20 端点级已自愈2s）；冷启首点 ~5s 初始化延迟；01:45:22 app 进程死亡原因不明（crash buffer 已滚走）。
> - 线级采集结论：B 类"设备拒收"降级待复核——两份无声场采集（sil_*/sil2_*）均 bit-perfect 到端点，但采样窗口与用户确认无声的时刻不完全重合。
> - **根因4（已修·架构级，2026-09-26 终审）**：切歌=closeSink→handle.stopInternal（native 拆但 claim 不放）→新解码器首帧 configure→handle.start 在持着的 claim 上对活端点 re-assert（claimed=true）→ECHO-A 端点进"URB 即刻完成、数据全吞"僵尸态→ring 永远 0 全绿无声（02:18:32 实锤：underrun 风暴+state=playing+pos 在走）。**修=会话驻留（UAPP 式）三刀**：①UacSink.configure 同(sr,ch,enc)幂等跳过 handle.start（切歌 USB 零操作）②plugin 切歌 shutdownPlayback(closeSink=false) 保留 sink/会话③stopInternal 端点规范下电 SET_INTERFACE alt=0（格式变化切歌也走干净下电→上电）。另修：rescue-open break 条件改 usbManager.deviceList（app 重启首曲误判扬声器场景跌 fallback 的问题）。`patch_keepalive.py`/`patch_rescue.py`。
> - **"当前输出=未建立输出"显示 bug（已修）**：svc.output 只在 openExclusive() 赋值而播放走 engine 直通没人更新→恒 none。修=usb_exclusive_service 挂 playbackEvents 驱动 refreshOutput() + refreshDevices 顺带刷新 + 设置页 initState 显式刷新。
> - **真无损终验 PASS（bp3，2026-09-26 02:52）**：44.1k/16bit/2ch，in 16.54s vs out 16.02s，对齐段 2744698B(15.56s) 逐字节一致，real_bad=0B，out_only_nonzero_segs=0，insert_zero=0；唯一差异=开头 80528B(0.457s) 已知开播补零空隙。bp_verify.py 已支持传参。
> **维护规则**：①开工先读本文档，不重复询问已写事实；②每完成节点立即更新「当前状态/下一步/坑」；③历史只追加一行；④文档>500 行时压缩历史。
> 最后更新：2026-09-25（开源自查轮收尾后压缩版）

## 一、项目概述

- 改造开源 Flutter 安卓音乐播放器 **FeiNiuMusic**（github.com/kuilei0926/FeiNiuMusic），连飞牛 NAS。
- 源码：`C:/Users/Lenovo/AppData/Local/hermes/workspace/FeiNiuMusic/`
- 两大需求：①**音频独占**：自研用户态 UAC 驱动（usbdevfs ISO URB，绕 AudioFlinger），USB DAC bit-perfect 直出；②**最无损输出**：默认 FLAC、恒直连、禁无损降级。
- **当前阶段**：开源发布前收尾——通用 DAC 兼容（任意小尾巴即插即用）+ P0/P1/P2 稳定性清单全修（代码+BUILD 已完成），待真机回归。
- 环境：真机 Realme RMX3161（Android 12）+ 真 DAC（TTGK ECHO-A 主测 / 戴灵 G3 压测）。用户只要结果一口气做完，严禁中途问。

## 二、历史关键节点（倒序，一行一条）

- **2026-09-25 开源自查轮（用户 P0/P1/P2 清单）**：全部补完并 BUILD 通过——P0-1 UAF 三层封死（decoder closed 守卫+nativeClose 无条件 join+joined 防 double-join+nativeWrite 停止返-1）；P0-2/P2-8 URB 指数退避 1→256ms+ENODEV 直退+32 连败优雅降级；P1-3 协商式 pickAlt（源率命中=bit-perfect，否则最接近率）+C++ 线性插值重采样+每 DAC 30min 一次弹窗；P1-4 TPDF dither 降位；P1-5 声道映射✅；P1-6 DeviceQuirks（VID:PID 补丁表）；P2-7 热插拔拔=暂停插回自动续播；minSdk 27→26+setChannelIndexMask API28 守卫。明细见 VERIFY_WORKLOG_G3.md。
- **2026-09-25 通用 DAC 兼容轮**：戴灵 G3（Jieli 3654:4255，UAC1 全速 48k-only）暴露 6 bug 全修：路由死循环（routeForSong 不查 failedSongIds）、采样率不拦、convertFrames 声道错帧、pickAlt 允许降位、AudioTrack >2ch 错帧、ENC_PCM_FLOAT 乱码。新功能：历史 DAC 列表、自动弹授权、手动授权按钮。
- **2026-09-25 二轮修复+真机复验 PASS**：FIX-1 getSpeedFd `_IO('U',15)→_IO('U',31)`；FIX-2 setSamplingFrequency EBUSY claim+重试+降级；FIX-3 队列刷新 resumeIfSame；FIX-4 **切歌 SIGABRT（UAF）**：残余 URB 悬垂指针→reap 所有权校验+排空+closeSink。切歌压测 3 轮零异常；verify_seg.py 三段真失真 0B → **bit-perfect PASS**。
- **2026-09-25 P4 位对位 PASS（核心结论）**：真 DAC ECHO-A 播 44.1k/16bit FLAC，URB 位流 vs 解码 PCM 比对 27.63MB **真失真 0B**（仅 876KB underrun 静音插入，全在网络卡顿点）。抓取链 `uac_cap_{in,out}.pcm + meta.txt`，比对器 `workspace/compare_capture3.py`（曲目切换产生会话边界→verify_seg.py 分段锚定）。
- **2026-09-25 独占链路连环排查**：根因①冷启动路由（settings ensureLoaded 只挂设置页→player_service `_init` 补）；根因②ECHO-A UAC2 精简描述符（FORMAT_TYPE 6B/AS_GENERAL 16B/无率表=时钟编程型）解析修复。
- **2026-09-25 代理拆除**：.env 死代理劫持 → 三处全拆，纯直连（唯一例外 api.b.ai 走 Clash 7897 仅限其客户端配置）。
- **2026-09-24/25 交付 v1**：自研用户态 USB 音频驱动全链路实机验证 + 转码改造（默认 FLAC/恒直连/禁降级）；577 单测过、MuMu 0 崩溃。
- **2026-09-24 调研定路线**：选用户态 UAC 驱动（Ma145/decent-player 思路）自研。

## 三、当前状态（最重要）

**enc fix + 音量修复已落地并真机验证；压测脚本 dac_stress.py 全链路跑通（1 轮 bit-perfect PASS）**。剩收尾（详见 HANDOFF.md §5）：

1. 桌面 GUI 抓取小工具（用户规格：只显示手机连接+USB 独占状态，手动开始/停止抓输出，检测内容单独文件夹，用户检查完再让 agent 分析）。
2. 多 DAC 换机压测（dac_stress.py 支持回车续测）。
3. 采集体量算术核对（各轮 in/out 3~5MB vs 名义时长）+ 21:02 轮 `audiotrack-fallback` 异常复测。
4. 44.1k 重采样回归 + 切歌/热插拔回归 + 50% 音量数值验证。

**已修复档案**：①24bit 噪声啸叫=inEnc 帧错位（声明 21 实际 2），enc fix（实测几何>outputFormat>请求值，保守 16bit）真机实锤 `enc fix: declared=21 actual=2`；②音量=UacSink 软件增益（appVolume×sysVolume 400ms 轮询，双满格旁路 bit-perfect）；③**Android 14+ 不弹 USB 授权**=FLAG_MUTABLE+隐式 PendingIntent 被 U+ 拒绝被 catch 吞掉，修复=`Intent(...).setPackage(packageName)`（小米15 Android 15 已验证：弹窗→授权→冷启动 sink=usb_uac 不重复弹）；④**16KB 对齐**=只有我们自己的 libusb_uac_output.so 未对齐，CMake 加 `-Wl,-z,max-page-size=16384`，check_16kb.py 复检 0/7；⑤**ECHO-A 爆音**=三层根因（时钟 SET_CUR 被 audioserver 占 iface0 的 usbfs claim 校验卡死→DAC 跑 48k 喂 44.1k 爆音 + ALSA 拆流 ENOENT 死循环降级 + 解码器误发 completed 幽灵会话双驱动互殴），6 处修复（uac2ClockCtrl wIndex hack / submitUrbRecover 端点自愈 / writeFailed 抑制 completed / 引擎 _stopped 守卫 / 两处 ALSA settle 300+250ms）SET_CUR 44100 ok、稳态 0 风暴，档案 HANDOFF §4 第四项。
**已知问题（用户裁定标记暂不处理）**：开播/切歌瞬间卡顿（稳态干净，26.7s 0 underrun 0 静音）——三件档案（600ms 预滚补零空隙+暂停不停 URB+偶发 30.5s stall）的证据链与既定修法在 HANDOFF.md §4 末，要修按档案动手。

## 四、产物与关键路径

| 产物 | 路径 |
|---|---|
| APK（debug/release） | `FeiNiuMusic/build/app/outputs/flutter-apk/` |
| 本轮工作台 | `FeiNiuMusic/VERIFY_WORKLOG_G3.md`（P0/P1/P2 自查表+修复明细） |
| ECHO-A 轮归档 | `FeiNiuMusic/VERIFY_WORKLOG.md` |
| 比对器 | `workspace/verify_seg.py`（段感知）、`workspace/compare_capture3.py` |
| mock fnOS 服务 | `workspace/mockfn/mock_server.py`（:5666，分页 page>1 返空） |

**代码地图**：插件 `plugins/usb_audio_exclusive/`（Kotlin：UsbAudioExclusivePlugin/NativeUac/UsbDeviceFinder/PcmSink/ExclusiveDecoder；C++：cpp/usb_uac_output.cpp）；Dart 引擎 `lib/app/services/player/usb_exclusive_engine.dart`、服务 `usb_exclusive/usb_exclusive_service.dart`、路由 `player/playback_router.dart`、核心 `player_service.dart`、设置页 `lib/pages/settings/exclusive_audio_settings_page.dart`。

**验证环境**：手机 adb `<测试机IP>:5555`（WiFi 名已隐去；有线 `/d/android-sdk/platform-tools/adb.exe`）；scrcpy `C:/Users/Lenovo/Downloads/scrcpy333/scrcpy-win64-v3.3.3/`；NAS `<你的NAS域名>:443`（局域网 `<局域网IP>:5666`）。logcat tag：UsbUacParse/UsbUacOutput/UsbDeviceFinder(negotiate)/UsbAudioExclusivePlugin(hotplug/notice)。

**构建**：`export ANDROID_HOME="D:/android-sdk" JAVA_HOME="C:/Program Files/Microsoft/jdk-17.0.19.10-hotspot"; unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; C:/Users/Lenovo/flutter/bin/flutter build apk --debug --target-platform android-arm64`（增量 20~100s）。

## 五、坑（别再踩）

1. **纯直连**：全局禁代理（.env/系统/环境），仅 api.b.ai 客户端内走 Clash(7897)。git-bash curl 中文 mangle，用 py 脚本。
2. **root 不可用**（Magisk 拒授权），一切验证不得依赖 root；三星 S22 是虚拟机忽略。
3. **UAC 描述符不守规范常见**：FORMAT_TYPE 可短至 6B、声道在 AS_GENERAL offset10/11、无率表=时钟编程型（rateMin==rateMax==0 要放行）→ DeviceQuirks 表打补丁。解析失败会静默回退 AudioTrack，诊断=逐描述符 hex logcat。
4. **USBDEVFS**：GET_SPEED=`_IO('U',31)`（`_IO('U',15)`是 CLAIMINTERFACE）；setSamplingFrequency EBUSY 自适应 DAC 无害（claim+重试+警告）。
5. **scoped storage**：app 私有文件用 `adb exec-out run-as com.feiniu.music cat` 拉取。
6. **比对器**：曲首静音锚点翻车；ringRead 补零是插入语义（只跳 out 不跳 exp）；曲目切换产生会话边界→分段锚定。
7. **编译**：C++ 只有 LOGI/LOGE 且日志必须 ASCII（NDK 内非 ASCII 乱码）；`execute_code` BLOCKED、heredoc 易被 blocklist（写 .py/.sh 执行）、search_files 路径 bug（用 terminal grep）、read_file 误判 usb_uac_output.cpp 二进制（用 sed）。
8. **Android 8.0 兼容**：minSdk=26；API28+ 调用（setChannelIndexMask）必须 SDK_INT 守卫。
9. **用户工作风格**：一口气做完再汇报；"卡了吗"=催进度立即给实质进展；.bat 纯 ASCII；文档驱动。

## 六、下一步（按序，详见 HANDOFF.md §5）

- [ ] 桌面 GUI 抓取小工具（规格见「当前状态」1）。
- [ ] 多 DAC 换机压测（dac_stress.py）+ 采集体量算术核对 + 21:02 轮 fallback 复测。
- [ ] 44.1k 重采样回归 + 切歌/热插拔 + 50% 音量数值验证。
- [ ] 真 NAS 端到端验证（替换 mock）+ 开源发布（LICENSE/README/兼容矩阵）。
- [ ] 非阻塞：underrun 优化、诊断日志降级。

## 七、更新日志

- 2026-09-25 夜：Android 14+ USB 授权不弹窗修复（PendingIntent setPackage）；小米15（Android 15）全流程验证通过；APK 更新（MD5 4f61f1ddd9bdacc62041cd11dbd4f3cf）。
- 2026-09-25 夜：enc fix+音量修复落地真机验证；dac_stress.py 全链路 PASS；采集 capReset 修复；HANDOFF.md 重写为修复后状态。
- 2026-09-25 开源自查轮收尾：压缩为精简版（历史合并、状态/规划刷新）。
- 2026-09-25 初版：Hermes 从 `mufqt3t7abjxxt`（752 条消息）提炼生成。
