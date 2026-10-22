import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../navigator_key.dart';
import '../../state/settings_exclusive_state.dart';
import '../feiniu/transcode_service.dart';
import 'package:usb_audio_exclusive/usb_audio_exclusive.dart';

export 'package:usb_audio_exclusive/usb_audio_exclusive.dart'
    show UsbAudioDevice, UsbKnownDevice, ExclusiveOutputInfo;

/// USB 音频独占输出服务（单例）。
///
/// 职责：
/// - 跟踪 USB 音频设备（UAC DAC）插拔；
/// - 决定歌曲是否走独占路由（[canRoute] / [supportsFormat]）；
/// - 独占模式语义：**原始未转码流 + bit-perfect 直出**（PCM 整数搬运，
///   不经 AudioFlinger/ALSA，不重采样，不软件调音量）。
class UsbExclusiveService {
  UsbExclusiveService._();

  static final UsbExclusiveService instance = UsbExclusiveService._();

  /// 已连接的 USB 音频设备列表。
  final ValueNotifier<List<UsbAudioDevice>> devices =
      ValueNotifier(const []);

  /// 最近一次输出后端信息（usb_uac / audiotrack / none）。
  final ValueNotifier<ExclusiveOutputInfo> output =
      ValueNotifier(const ExclusiveOutputInfo(backend: 'none'));

  /// 播放失败（独占路由无法解码/输出）的歌，本会话不再路由独占。
  final Set<String> failedSongIds = {};

  StreamSubscription<List<UsbAudioDevice>>? _devSub;
  StreamSubscription<String>? _noticeSub;
  StreamSubscription<ExclusivePlaybackEvent>? _evSub;
  bool _started = false;

  /// 开始监听设备插拔（幂等）。
  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    await AppExclusiveAudioSettings.ensureLoaded();
    _devSub = UsbAudioExclusive.deviceEvents.listen((list) {
      devices.value = list;
      unawaited(_autoRequestPermission(list));
    });
    // P1-3：重采样/降位一次性提示（原生层已按 DAC 30 分钟节流）。
    _noticeSub = UsbAudioExclusive.noticeEvents.listen(_showNotice);
    // 播放事件驱动"当前输出"刷新：设置页实时显示 usb_uac/audiotrack。
    // 之前只有 openExclusive() 赋值，而播放走 engine 直通 → 恒"未建立输出"。
    _evSub = UsbAudioExclusive.playbackEvents.listen((_) => unawaited(refreshOutput()));
    await refreshDevices();
    await _autoRequestPermission(devices.value);
  }

  /// 弹一次性提示（重采样/降位 dither 等协商结果）。
  void _showNotice(String message) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('USB 独占输出提示'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> refreshDevices() async {
    try {
      devices.value = await UsbAudioExclusive.listDevices();
    } catch (_) {
      // 非 Android / 通道不可用：保持空列表。
    }
    await refreshOutput();
  }

  /// 刷新"当前输出"（usb_uac / audiotrack / none）。
  Future<void> refreshOutput() async {
    try {
      output.value = await UsbAudioExclusive.outputInfo();
    } catch (_) {
      // 通道不可用：保持旧值。
    }
  }

  /// 新 DAC 授权引导：独占已开 + 有设备但未授权 → 主动弹一次系统授权
  /// 弹窗（每个设备只弹一次/会话）。避免「新设备插入 → 独占静默失效
  /// 回退 audiotrack → 用户以为在 bit-perfect」。
  final Set<String> _permPrompted = {};
  Future<void> _autoRequestPermission(List<UsbAudioDevice> list) async {
    if (!AppExclusiveAudioSettings.enabled.value) return;
    if (list.isEmpty) return;
    final dev = list.first;
    if (dev.hasPermission) return;
    final key = dev.idLabel;
    if (_permPrompted.contains(key)) return;
    _permPrompted.add(key);
    try {
      await UsbAudioExclusive.requestPermission();
    } catch (e) {
      debugPrint('[UsbExclusive] requestPermission failed: $e');
    }
    // 授权结果落定后刷新 hasPermission。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await refreshDevices();
  }

  /// 历史连接过的 DAC（设置页展示）。
  Future<List<UsbKnownDevice>> knownDevices() async {
    try {
      return await UsbAudioExclusive.knownDevices();
    } catch (_) {
      return const [];
    }
  }

  /// 当前设备是否支持该采样率（能力未知放行，pickAlt 兜底）。
  bool supportsRate(int? rate) {
    final list = devices.value;
    if (list.isEmpty) return true;
    // 任一设备支持即可路由（多设备场景取第一个=Kotlin 端 open 顺序）。
    return list.first.supportsRate(rate);
  }

  /// 尝试打开 USB 独占输出。成功返回 true。
  Future<bool> openExclusive() async {
    try {
      final info = await UsbAudioExclusive.open();
      output.value = info;
      return true;
    } catch (e) {
      debugPrint('[UsbExclusive] open failed: $e');
      return false;
    }
  }

  Future<void> closeExclusive() async {
    try {
      await UsbAudioExclusive.close();
    } catch (_) {}
    output.value = const ExclusiveOutputInfo(backend: 'none');
  }

  bool get deviceAttached => devices.value.isNotEmpty;

  /// 是否允许独占路由（开关开 + （有 USB DAC 或允许回退直通））。
  bool get canRoute {
    if (!AppExclusiveAudioSettings.enabled.value) return false;
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    return deviceAttached || AppExclusiveAudioSettings.fallbackInternal.value;
  }

  /// 是否有 USB 独占设备（无则为回退直通）。
  bool get hasUsbDevice => deviceAttached;

  /// MediaCodec 能否原生解码该格式（独占管线解码器）。
  ///
  /// DSD/APE/WMA/DTS 等需要 FFmpeg 软解的格式不走独占（回退 media_kit），
  /// EAC3/ALAC 等设备解码不可靠的编码同样排除。
  static const Set<String> nativelyDecodable = {
    'flac', 'wav', 'wave', 'mp3', 'mp2', 'aac', 'm4a', 'mp4', '3gp',
    'ogg', 'oga', 'opus', 'webm', 'amr', 'awb', 'mka',
  };

  bool supportsFormat(String? format, {String? codec}) {
    if (FeiNiuTranscodeService.isMediaKitCodec(codec)) return false;
    final f = (format ?? '').trim().toLowerCase();
    if (f.isEmpty) return true; // 未知格式按可解码处理（解码失败有兜底）
    return nativelyDecodable.contains(f) &&
        !FeiNiuTranscodeService.isMediaKitFormat(f);
  }

  void dispose() {
    _devSub?.cancel();
    _noticeSub?.cancel();
  }
}
