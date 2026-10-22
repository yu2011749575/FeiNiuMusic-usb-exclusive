import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DLNA 投屏设置。
///
/// - [enabled]「投屏（DLNA）」总开关：关（默认）→ 播放页不显示投屏按钮、不启动发现。
class DlnaCastSettings {
  static const String _prefsEnabled = 'dlna_cast_enabled';

  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    enabled.value = false;
  }
}
