import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_theme_state.dart';
import 'package:feiniu_music/app/theme/app_visual_theme.dart';

void main() {
  test(
    'legacy visual style preference is ignored in MIUIX-only mode',
    () async {
      SharedPreferences.setMockInitialValues({
        'setting_visual_style': 'classic',
      });

      await AppThemeSettings.ensureLoaded();
      expect(AppThemeSettings.visualStyle.value, AppVisualStyle.miuix);
    },
  );

  test('MIUIX switch has distinct on and off tracks', () {
    final source = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3B82F6),
      brightness: Brightness.light,
    );
    final theme = buildMiuixMaterialTheme(
      ThemeData(colorScheme: source, useMaterial3: true),
      source,
    );
    final track = theme.switchTheme.trackColor!;
    final off = track.resolve(const <WidgetState>{})!;
    final on = track.resolve(const <WidgetState>{WidgetState.selected})!;

    expect(off, isNot(theme.colorScheme.surface));
    expect(on, theme.colorScheme.primary);
    expect(off, isNot(on));
  });
}
