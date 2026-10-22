import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通知歌词灵动岛设置。
///
/// 独立于 [MediaNotificationSettings]（audio_service 媒体通知）：这里控制的是
/// HyperOS/MIUI「焦点通知」渲染在系统灵动岛的歌词卡片。默认关闭。
class IslandLyricSettings {
  /// 通知类型：0 = 实时通知（无 root/Shizuku，走标准实时通知接口上岛）；
  /// 1 = 焦点通知（MIUI 焦点通知 JSON，需系统焦点通知白名单放行）。
  static const int typeLive = 0;
  static const int typeFocus = 1;

  static const String _prefsEnabled = 'island_lyric_enabled';
  static const String _prefsShowProgress = 'island_lyric_show_progress';
  static const String _prefsTestMode = 'island_lyric_test_mode';
  static const String _prefsAodLyrics = 'island_lyric_aod_lyrics';
  static const String _prefsNotificationType = 'island_lyric_notification_type';
  static const String _prefsBypassFocusLimit = 'island_lyric_bypass_focus_limit';

  static final ValueNotifier<bool> enabled = ValueNotifier(false);
  static final ValueNotifier<bool> showProgress = ValueNotifier(true);

  /// 通知类型：默认实时通知（[typeLive]），无 root/Shizuku 直接上岛。
  /// 见类注释的 [typeLive]/[typeFocus]。
  static final ValueNotifier<int> notificationType = ValueNotifier(typeLive);

  /// 测试模式：打开后即使不播放也持续模拟发送通知，用于验证暂停/无播放时
  /// 灵动岛是否仍能渲染。默认关闭。
  static final ValueNotifier<bool> testMode = ValueNotifier(false);

  /// 息屏歌词：开启后把当前歌词帧输出到通知标题（aodTitle），息屏（AOD）时
  /// 显示封面 + 歌词，替代默认的歌名标题。默认关闭。
  static final ValueNotifier<bool> aodLyrics = ValueNotifier(false);

  /// Shizuku 绕过焦点通知白名单：开启后在发送焦点通知的前后短暂拦截/恢复
  /// XMSF 网络，使未在白名单内的应用也能渲染焦点通知。默认关闭。仅对
  /// [typeFocus] 生效（实时通知无需白名单）。
  static final ValueNotifier<bool> bypassFocusLimit = ValueNotifier(false);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    showProgress.value = prefs.getBool(_prefsShowProgress) ?? true;
    testMode.value = prefs.getBool(_prefsTestMode) ?? false;
    aodLyrics.value = prefs.getBool(_prefsAodLyrics) ?? false;
    notificationType.value = prefs.getInt(_prefsNotificationType) ?? typeLive;
    bypassFocusLimit.value = prefs.getBool(_prefsBypassFocusLimit) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }

  static Future<void> setShowProgress(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowProgress, value);
    showProgress.value = value;
  }

  /// 设置通知类型（[typeLive] 或 [typeFocus]）。
  static Future<void> setNotificationType(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsNotificationType, value);
    notificationType.value = value;
  }

  static Future<void> setTestMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTestMode, value);
    testMode.value = value;
  }

  static Future<void> setAodLyrics(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAodLyrics, value);
    aodLyrics.value = value;
  }

  /// 设置是否用 Shizuku 绕过焦点通知白名单。
  static Future<void> setBypassFocusLimit(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsBypassFocusLimit, value);
    bypassFocusLimit.value = value;
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    enabled.value = false;
    showProgress.value = true;
    testMode.value = false;
    aodLyrics.value = false;
    notificationType.value = typeLive;
    bypassFocusLimit.value = false;
  }
}
