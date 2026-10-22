import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StatusBarSettings {
  static const String _prefsEnabled = 'status_bar_enabled';

  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? true;
    enabled.addListener(_persist);
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, enabled.value);
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }
}
