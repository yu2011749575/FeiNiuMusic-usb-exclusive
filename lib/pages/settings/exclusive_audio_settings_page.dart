import 'package:flutter/material.dart';
import 'package:usb_audio_exclusive/usb_audio_exclusive.dart';

import '../../app/services/usb_exclusive/usb_exclusive_service.dart';
import '../../app/state/settings_exclusive_state.dart';
import '../../components/index.dart';

/// 音频独占设置页：USB DAC 独占模式（bit-perfect 直出）。
class ExclusiveAudioSettingsPage extends StatefulWidget {
  const ExclusiveAudioSettingsPage({super.key});

  @override
  State<ExclusiveAudioSettingsPage> createState() =>
      _ExclusiveAudioSettingsPageState();
}

class _ExclusiveAudioSettingsPageState
    extends State<ExclusiveAudioSettingsPage> {
  @override
  void initState() {
    super.initState();
    AppExclusiveAudioSettings.ensureLoaded();
    UsbExclusiveService.instance.ensureStarted();
    // 二次进页 ensureStarted 幂等早退 → 显式刷新一次"当前输出"。
    UsbExclusiveService.instance.refreshOutput();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );
    final svc = UsbExclusiveService.instance;
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '音频独占',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '独占模式',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppExclusiveAudioSettings.enabled,
                builder: (context, enabled, _) {
                  final children = <Widget>[
                    AppSettingSwitchTile(
                      title: '音频独占模式',
                      subtitle: 'USB DAC 独占输出：原始未转码流 → DAC，位完美直出',
                      value: enabled,
                      onChanged: (v) async {
                        await AppExclusiveAudioSettings.setEnabled(v);
                        if (v) {
                          await svc.ensureStarted();
                          if (svc.deviceAttached) {
                            await svc.openExclusive();
                          }
                        } else {
                          await svc.closeExclusive();
                        }
                        if (mounted) setState(() {});
                      },
                    ),
                  ];
                  if (enabled) {
                    children.add(
                      ValueListenableBuilder<bool>(
                        valueListenable:
                            AppExclusiveAudioSettings.fallbackInternal,
                        builder: (context, fallback, _) {
                          return AppSettingSwitchTile(
                            title: '无 USB DAC 时直通输出',
                            subtitle: '解码 PCM 原采样率直出（不经转码/系统音效）；'
                                '关闭则无设备时回退常规链路',
                            value: fallback,
                            onChanged: (v) async {
                              await AppExclusiveAudioSettings.setFallbackInternal(v);
                              if (mounted) setState(() {});
                            },
                          );
                        },
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  );
                },
              ),
            ],
          ),
          AppSettingSection(
            title: '设备与输出',
            children: [
              ValueListenableBuilder<List<UsbAudioDevice>>(
                valueListenable: svc.devices,
                builder: (context, devices, _) {
                  if (devices.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: Text('未检测到 USB 音频设备（插入 USB DAC 后自动识别）'),
                    );
                  }
                  return Column(
                    children: [
                      for (final d in devices)
                        ListTile(
                          title: Text(d.name),
                          subtitle: Text(
                            '${d.idLabel}'
                            '${d.hasPermission ? '' : ' · 未授权（播放时将弹出授权）'}',
                          ),
                          leading: const Icon(Icons.usb),
                          trailing: d.hasPermission
                              ? const Icon(Icons.check_circle_outline)
                              : IconButton(
                                  icon: const Icon(Icons.lock_open),
                                  tooltip: '请求 USB 授权',
                                  onPressed: () async {
                                    await UsbAudioExclusive.requestPermission();
                                    await svc.refreshDevices();
                                    if (mounted) setState(() {});
                                  },
                                ),
                        ),
                    ],
                  );
                },
              ),
              ValueListenableBuilder<ExclusiveOutputInfo>(
                valueListenable: svc.output,
                builder: (context, info, _) {
                  final label = switch (info.backend) {
                    'usb_uac' => 'USB 独占（bit-perfect）'
                        '${info.sampleRate > 0 ? ' · ${info.sampleRate}Hz '
                            '${info.bitDepth}bit ${info.channels}ch' : ''}',
                    'audiotrack' => '直通输出'
                        '${info.sampleRate > 0 ? ' · ${info.sampleRate}Hz' : ''}',
                    _ => '未建立输出',
                  };
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Text('当前输出：$label'),
                  );
                },
              ),
              ListTile(
                title: const Text('刷新设备'),
                leading: const Icon(Icons.refresh),
                onTap: () async {
                  await svc.refreshDevices();
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          AppSettingSection(
            title: '连接过的 DAC 设备',
            children: [
              FutureBuilder<List<UsbKnownDevice>>(
                future: svc.knownDevices(),
                builder: (context, snap) {
                  final list = snap.data ?? const <UsbKnownDevice>[];
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: Text('还没有连接过 USB DAC'),
                    );
                  }
                  final now = DateTime.now();
                  String when(int ms) {
                    if (ms <= 0) return '';
                    final d = DateTime.fromMillisecondsSinceEpoch(ms);
                    final diff = now.difference(d);
                    if (diff.inMinutes < 1) return '刚刚';
                    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
                    if (diff.inDays < 1) return '${diff.inHours} 小时前';
                    return '${d.year}-${d.month.toString().padLeft(2, '0')}'
                        '-${d.day.toString().padLeft(2, '0')}';
                  }

                  return Column(
                    children: [
                      for (final k in list)
                        ListTile(
                          dense: true,
                          title: Text(k.name),
                          subtitle: Text('${k.idLabel} · 最近 ${when(k.lastSeen)}'),
                          leading: const Icon(Icons.usb_outlined),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
          AppSettingSection(
            title: '说明',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Text(
                  '独占模式经用户态 USB 音频驱动（等时传输）直接输出到 DAC，'
                  '绕过系统混音与重采样，解码位流与 DAC 收到的位完全一致。'
                  '播放恒用原始未转码流；系统音量被旁路，请用 DAC 硬件音量。'
                  'DSD/APE/WMA 等需软解的格式自动回退常规链路。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
