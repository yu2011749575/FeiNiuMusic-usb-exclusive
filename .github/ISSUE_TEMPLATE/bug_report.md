---
name: Bug 反馈
about: USB 独占 / 播放问题反馈模板
title: "[Bug] "
labels: bug
assignees: ''
---

## 设备与环境

- 手机型号 / Android 版本：
- DAC 型号（重要，不同 DAC 表现不同）：
- App 版本（APK 文件名或 Release 版本号）：
- 音源格式（如 FLAC 24bit/48kHz）：

## 问题描述

- 发生场景（开播 / 切歌 / seek / 长时间播放 / 其他）：
- 复现步骤：
1.
2.
3.
- 预期 vs 实际：

## 日志（能贴就贴，非常有助于定位）

```text
# logcat 过滤命令（电脑连上手机后执行）：
# adb logcat -d -s UsbUacOutput:I UsbUacParse:I UsbDeviceFinder:I UsbAudioExclusivePlugin:I "I flutter" | tail -120
粘贴到这里
```

## 补充

- [ ] 我已阅读 README 中的「已知问题」，本 bug 不在其中
- 其他信息（截图、是否 root、是否同时连接其他音频设备等）：
