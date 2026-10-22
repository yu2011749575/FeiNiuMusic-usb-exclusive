import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/settings_state.dart';

/// macOS 窗口背景同步：把 Flutter 主题背景色同步到原生 FlutterView。
///
/// 引擎默认 FlutterView 的 layer 背景是黑色（引擎 FlutterView.mm 里
/// `[self setBackgroundColor:[NSColor blackColor]]`，仅当显式设置才覆盖）。
/// 滚动/切页时若某帧合成不及时，Metal layer 露出黑底 → 整窗「黑屏闪烁」
/// （亮色模式下对白底页面尤其刺眼）。
///
/// 把原生背景色设为与主题一致的底色（与 app_visual_theme.dart 的
/// `background` 保持一致）后，合成间隙显示的是页面底色而非黑，闪烁消失。
/// 跟随 [AppThemeSettings.themeMode] 与系统亮暗变化实时更新，仅 macOS 启用。
class MacosWindowBackgroundService {
  static const MethodChannel _channel = MethodChannel(
    'com.feiniu.music/window',
  );

  static bool _started = false;

  /// 与 app_visual_theme.dart `buildMiuixMaterialTheme` 的 background 保持一致。
  static const Color _darkBackground = Color(0xFF080808);
  static const Color _lightBackground = Color(0xFFF7F7F7);

  static Future<void> init() async {
    if (!Platform.isMacOS) return;
    if (_started) return;
    _started = true;

    AppThemeSettings.themeMode.addListener(_push);
    // 链式保留已有回调，避免覆盖其它组件注册的系统亮暗监听。
    final previous = WidgetsBinding
        .instance
        .platformDispatcher
        .onPlatformBrightnessChanged;
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        () {
      previous?.call();
      _push();
    };

    _push();
  }

  static void _push() {
    final dark = _resolvedBrightness() == Brightness.dark;
    final color = dark ? _darkBackground : _lightBackground;
    // fire-and-forget：首次发送若落在原生通道注册前（极少数启动竞态），
    // 原生侧已按 NSApp.effectiveAppearance 设好初始底色，后续主题变化会再推。
    _channel
        .invokeMethod<void>('setBackgroundColor', color.toARGB32())
        .catchError((_) {});
  }

  static Brightness _resolvedBrightness() {
    switch (AppThemeSettings.themeMode.value) {
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }
}
