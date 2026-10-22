import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 音频独占模式设置。
///
/// - [enabled]「音频独占模式」：开 → 播放走 USB DAC 独占 bit-perfect 直出
///   （用户态 UAC2 驱动，绕过 AudioFlinger/ALSA/系统混音），强制原始未转码流；
///   关 → 常规播放链路。
/// - [fallbackInternal]「无 USB DAC 时直通输出」：开 → 未插入 USB DAC 时
///   用解码 PCM 直出（原采样率 AudioTrack，不走转码）；关 → 无设备时回退
///   常规链路。
class AppExclusiveAudioSettings {
  static const String _prefsEnabled = 'exclusive_audio_enabled';
  static const String _prefsFallback = 'exclusive_audio_fallback';

  static final ValueNotifier<bool> enabled = ValueNotifier(false);
  static final ValueNotifier<bool> fallbackInternal = ValueNotifier(true);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    fallbackInternal.value = prefs.getBool(_prefsFallback) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }

  static Future<void> setFallbackInternal(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsFallback, value);
    fallbackInternal.value = value;
  }

  /// 测试专用：重置内存状态。
  static void resetForTest() {
    _loading = null;
    enabled.value = false;
    fallbackInternal.value = true;
  }
}
