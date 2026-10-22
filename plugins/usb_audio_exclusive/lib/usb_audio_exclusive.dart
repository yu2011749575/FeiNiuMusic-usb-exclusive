import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// 已连接的 USB 音频设备（UAC1/UAC2 DAC）。
class UsbAudioDevice {
  const UsbAudioDevice({
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.deviceId,
    this.manufacturer,
    this.hasPermission = false,
    this.rates = const [],
    this.rateMin = 0,
    this.rateMax = 0,
    this.bitDepths = const [],
    this.channels = const [],
  });

  final String name;
  final int vendorId;
  final int productId;
  final int deviceId;
  final String? manufacturer;

  /// 系统 USB 授权是否已授予（未授予时独占无法打开）。
  final bool hasPermission;

  /// 设备能力缓存（首次成功打开后才有；空=未知，路由层放行）。
  final List<int> rates;
  final int rateMin;
  final int rateMax;
  final List<int> bitDepths;
  final List<int> channels;

  /// 设备是否支持该采样率。能力未知（从未打开过）时放行——
  /// 播放时 pickAlt 兜底，失败只回退不崩。
  bool supportsRate(int? rate) {
    if (rate == null || rate <= 0) return true;
    if (rates.isNotEmpty) return rates.contains(rate);
    if (rateMin > 0 && rateMax > 0) return rate >= rateMin && rate <= rateMax;
    return true;
  }

  String get idLabel =>
      'VID:${vendorId.toRadixString(16).padLeft(4, '0')} '
      'PID:${productId.toRadixString(16).padLeft(4, '0')}';

  factory UsbAudioDevice.fromMap(Map<dynamic, dynamic> m) {
    List<int> ints(dynamic v) {
      if (v is List) return v.map((e) => (e as num).toInt()).toList();
      return const [];
    }

    // caps 是 Kotlin 端落盘的 JSON 字符串（可空）。
    List<int> capInts(String key) {
      final caps = m['caps'];
      if (caps is! String || caps.isEmpty) return const [];
      try {
        final obj = jsonDecode(caps) as Map<String, dynamic>;
        return ints(obj[key]);
      } catch (_) {
        return const [];
      }
    }

    int capInt(String key) {
      final caps = m['caps'];
      if (caps is! String || caps.isEmpty) return 0;
      try {
        final obj = jsonDecode(caps) as Map<String, dynamic>;
        return (obj[key] as num?)?.toInt() ?? 0;
      } catch (_) {
        return 0;
      }
    }

    return UsbAudioDevice(
      name: (m['name'] as String?) ?? 'USB Audio Device',
      vendorId: (m['vendorId'] as num?)?.toInt() ?? 0,
      productId: (m['productId'] as num?)?.toInt() ?? 0,
      deviceId: (m['deviceId'] as num?)?.toInt() ?? 0,
      manufacturer: m['manufacturer'] as String?,
      hasPermission: m['hasPermission'] == true,
      rates: capInts('rates'),
      rateMin: capInt('rateMin'),
      rateMax: capInt('rateMax'),
      bitDepths: capInts('bitDepths'),
      channels: capInts('channels'),
    );
  }
}

/// 历史连接过的 DAC 设备（设置页展示）。
class UsbKnownDevice {
  const UsbKnownDevice({
    required this.name,
    required this.vendorId,
    required this.productId,
    this.manufacturer,
    this.firstSeen = 0,
    this.lastSeen = 0,
  });

  final String name;
  final int vendorId;
  final int productId;
  final String? manufacturer;
  final int firstSeen;
  final int lastSeen;

  String get idLabel =>
      'VID:${vendorId.toRadixString(16).padLeft(4, '0')} '
      'PID:${productId.toRadixString(16).padLeft(4, '0')}';

  factory UsbKnownDevice.fromMap(Map<dynamic, dynamic> m) => UsbKnownDevice(
        name: (m['name'] as String?) ?? 'USB Audio Device',
        vendorId: (m['vendorId'] as num?)?.toInt() ?? 0,
        productId: (m['productId'] as num?)?.toInt() ?? 0,
        manufacturer: m['manufacturer'] as String?,
        firstSeen: (m['firstSeen'] as num?)?.toInt() ?? 0,
        lastSeen: (m['lastSeen'] as num?)?.toInt() ?? 0,
      );
}

/// 当前输出后端信息。[backend]：
/// - `usb_uac`：USB DAC 独占（bit-perfect，usbdevfs 等时传输）
/// - `audiotrack`：直通回退（无 USB DAC 时，原采样率 PCM 直出）
/// - `none`：未建立输出
class ExclusiveOutputInfo {
  const ExclusiveOutputInfo({
    required this.backend,
    this.deviceName,
    this.sampleRate = 0,
    this.bitDepth = 0,
    this.channels = 0,
  });

  final String backend;
  final String? deviceName;
  final int sampleRate;
  final int bitDepth;
  final int channels;

  factory ExclusiveOutputInfo.fromMap(Map<dynamic, dynamic> m) =>
      ExclusiveOutputInfo(
        backend: (m['backend'] as String?) ?? 'none',
        deviceName: m['deviceName'] as String?,
        sampleRate: (m['sampleRate'] as num?)?.toInt() ?? 0,
        bitDepth: (m['bitDepth'] as num?)?.toInt() ?? 0,
        channels: (m['channels'] as num?)?.toInt() ?? 0,
      );
}

/// 独占播放状态事件。[state]：
/// `idle / loading / ready / playing / paused / completed / error`
class ExclusivePlaybackEvent {
  const ExclusivePlaybackEvent({
    required this.state,
    this.positionMs = 0,
    this.durationMs,
    this.message,
  });

  final String state;
  final int positionMs;
  final int? durationMs;
  final String? message;

  factory ExclusivePlaybackEvent.fromMap(Map<dynamic, dynamic> m) =>
      ExclusivePlaybackEvent(
        state: (m['state'] as String?) ?? 'idle',
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (m['durationMs'] as num?)?.toInt(),
        message: m['message'] as String?,
      );
}

/// USB 音频独占输出（Android）。
///
/// 实现方式（自研，参考开源 decent-player 的技术路线）：
/// - **USB DAC 独占**：不经 AudioFlinger / AudioTrack / AAudio / ALSA /
///   内核 `snd-usb-audio`，直接通过 Linux `usbdevfs` 的等时传输（ISO URB）
///   把 PCM 写给 DAC。DAC 被 usbfs 绑定后系统混音器无法介入，
///   解码出的位（bit）即 DAC 收到的位 —— bit-perfect。
/// - **解码管线**：MediaExtractor + MediaCodec 输出原始 PCM
///   （16/24/32 位整数），全程整数位移搬运，无 float 混音、无重采样。
/// - **回退**：未插入 USB DAC（或设备打开失败）时回退 AudioTrack 直通
///   （原采样率 PCM 直出，不用系统音效/重采样链路）。
class UsbAudioExclusive {
  UsbAudioExclusive._();

  static const MethodChannel _methods =
      MethodChannel('usb_audio_exclusive/methods');
  static const EventChannel _events = EventChannel('usb_audio_exclusive/events');

  static StreamSubscription<dynamic>? _sub;
  static final StreamController<ExclusivePlaybackEvent> _playback =
      StreamController.broadcast();
  static final StreamController<List<UsbAudioDevice>> _devices =
      StreamController.broadcast();
  static final StreamController<String> _notices = StreamController.broadcast();

  /// 播放状态事件流（state/position/duration）。
  static Stream<ExclusivePlaybackEvent> get playbackEvents {
    _ensureSubscribed();
    return _playback.stream;
  }

  /// 一次性提示流（重采样/降位等协商结果；原生层已按 DAC 节流）。
  static Stream<String> get noticeEvents {
    _ensureSubscribed();
    return _notices.stream;
  }

  /// USB 音频设备插拔事件流（每次推全量列表）。
  static Stream<List<UsbAudioDevice>> get deviceEvents {
    _ensureSubscribed();
    return _devices.stream;
  }

  static void _ensureSubscribed() {
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      switch (e['kind']) {
        case 'playback':
          _playback.add(ExclusivePlaybackEvent.fromMap(e));
        case 'devices':
          final list = (e['devices'] as List? ?? const [])
              .whereType<Map<dynamic, dynamic>>()
              .map(UsbAudioDevice.fromMap)
              .toList(growable: false);
          _devices.add(list);
        case 'notice':
          final msg = e['message'];
          if (msg is String && msg.isNotEmpty) _notices.add(msg);
      }
    });
  }

  /// 枚举当前连接的 USB 音频设备。
  static Future<List<UsbAudioDevice>> listDevices() async {
    final raw = await _methods.invokeMethod<List>('listDevices');
    return (raw ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(UsbAudioDevice.fromMap)
        .toList(growable: false);
  }

  /// 历史连接过的 DAC 设备（跨会话持久）。
  static Future<List<UsbKnownDevice>> knownDevices() async {
    final raw = await _methods.invokeMethod<List>('knownDevices');
    return (raw ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(UsbKnownDevice.fromMap)
        .toList(growable: false);
  }

  /// 主动弹出系统 USB 授权弹窗（新设备首次使用引导）。已授权返回 true。
  static Future<bool> requestPermission() async {
    final ok = await _methods.invokeMethod<bool>('requestPermission');
    return ok ?? false;
  }

  /// 打开独占输出（申请 USB 权限 → claim → 选 alt setting）。失败抛
  /// [PlatformException]。
  static Future<ExclusiveOutputInfo> open() async {
    final m = await _methods.invokeMapMethod<dynamic, dynamic>('open');
    return ExclusiveOutputInfo.fromMap(m ?? const {});
  }

  /// 关闭独占输出，释放 USB 设备（拔出后内核恢复 snd-usb-audio）。
  static Future<void> close() => _methods.invokeMethod<void>('close');

  /// 播放一首歌（URL 或本地文件）。独占管线固定走**原始未转码流**。
  static Future<void> play({
    required String url,
    Map<String, String> headers = const {},
    bool isFile = false,
    int startMs = 0,
    int? endMs,
    String? title,
  }) =>
      _methods.invokeMethod<void>('play', {
        'url': url,
        'headers': headers,
        'isFile': isFile,
        'startMs': startMs,
        'endMs': endMs,
        'title': title,
      });

  static Future<void> pause() => _methods.invokeMethod<void>('pause');
  static Future<void> resume() => _methods.invokeMethod<void>('resume');

  static Future<void> seek(int positionMs) =>
      _methods.invokeMethod<void>('seek', {'ms': positionMs});

  static Future<void> stop() => _methods.invokeMethod<void>('stop');

  /// 音量（0.0–1.0）。仅回退 AudioTrack 后端生效——USB 独占为 bit-perfect，
  /// 不做软件衰减（音量请用 DAC 硬件音量）。
  static Future<void> setVolume(double value) =>
      _methods.invokeMethod<void>('setVolume', {'value': value});

  /// 查询当前输出与播放状态。
  static Future<ExclusiveOutputInfo> outputInfo() async {
    final m = await _methods.invokeMapMethod<dynamic, dynamic>('outputInfo');
    return ExclusiveOutputInfo.fromMap(m ?? const {});
  }
}
