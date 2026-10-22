import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlayerStylePreset { classic, poster }

extension PlayerStylePresetLabel on PlayerStylePreset {
  String get label {
    switch (this) {
      case PlayerStylePreset.classic:
        return '默认';
      case PlayerStylePreset.poster:
        return '海报歌词';
    }
  }

  String get description {
    switch (this) {
      case PlayerStylePreset.classic:
        return '沿用当前播放器布局';
      case PlayerStylePreset.poster:
        return '大封面海报与底部控制';
    }
  }
}

class PlayerStyleSettings {
  static const String _prefsStylePreset = 'player_style_preset';

  static final ValueNotifier<PlayerStylePreset> stylePreset = ValueNotifier(
    PlayerStylePreset.classic,
  );

  static Future<void>? _loading;

  static PlayerStylePreset _presetFromString(String? raw) {
    switch (raw) {
      case 'poster':
        return PlayerStylePreset.poster;
      default:
        return PlayerStylePreset.classic;
    }
  }

  static String _presetToString(PlayerStylePreset preset) {
    switch (preset) {
      case PlayerStylePreset.classic:
        return 'classic';
      case PlayerStylePreset.poster:
        return 'poster';
    }
  }

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    stylePreset.value = _presetFromString(prefs.getString(_prefsStylePreset));
  }

  static Future<void> setStylePreset(PlayerStylePreset preset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsStylePreset, _presetToString(preset));
    stylePreset.value = preset;
  }
}
