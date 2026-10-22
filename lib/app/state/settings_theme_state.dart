import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppVisualStyle { miuix }

class AppThemeSettings {
  static const String _prefsThemeMode = 'setting_theme_mode';
  static const String _prefsDynamicColor = 'setting_dynamic_color_enabled';
  static const String _prefsThemeSeedColor = 'setting_theme_seed_color';

  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier(
    ThemeMode.system,
  );
  static final ValueNotifier<bool> dynamicColorEnabled = ValueNotifier(false);
  static final ValueNotifier<Color?> themeSeedColor = ValueNotifier(null);
  static final ValueNotifier<AppVisualStyle> visualStyle = ValueNotifier(
    AppVisualStyle.miuix,
  );

  static Future<void>? _loading;

  static ThemeMode _modeFromString(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _modeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    themeMode.value = _modeFromString(prefs.getString(_prefsThemeMode));
    dynamicColorEnabled.value = prefs.getBool(_prefsDynamicColor) ?? false;
    final seed = prefs.getInt(_prefsThemeSeedColor);
    themeSeedColor.value = seed == null ? null : Color(seed);
    visualStyle.value = AppVisualStyle.miuix;
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsThemeMode, _modeToString(mode));
    themeMode.value = mode;
  }

  static Future<void> setDynamicColorEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsDynamicColor, enabled);
    dynamicColorEnabled.value = enabled;
  }

  static Future<void> setThemeSeedColor(Color? color) async {
    final prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_prefsThemeSeedColor);
      themeSeedColor.value = null;
      return;
    }
    await prefs.setInt(_prefsThemeSeedColor, color.toARGB32());
    themeSeedColor.value = color;
  }
}
