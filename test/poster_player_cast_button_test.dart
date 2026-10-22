import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_cast_state.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/state/settings_player_style_state.dart';
import 'package:feiniu_music/pages/player/player_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'dlna_cast_enabled': true});
    AppLayoutSettings.resetForTest();
    DlnaCastSettings.resetForTest();
    PlayerStyleSettings.stylePreset.value = PlayerStylePreset.poster;
  });

  tearDown(() {
    PlayerStyleSettings.stylePreset.value = PlayerStylePreset.classic;
    DlnaCastSettings.resetForTest();
    AppLayoutSettings.resetForTest();
  });

  testWidgets('海报模式在封面右上角显示投屏按钮', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await DlnaCastSettings.ensureLoaded();

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.cast), findsOneWidget);
    final buttonRect = tester.getRect(find.byIcon(Icons.cast));
    expect(buttonRect.center.dx, greaterThan(340));
    expect(buttonRect.center.dy, lessThan(80));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
