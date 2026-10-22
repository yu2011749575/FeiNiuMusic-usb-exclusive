import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/home/widgets/home_hero_banner.dart';

void _noop() {}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() => AppLayoutSettings.resetForTest());

  Widget buildBanner() {
    return const MaterialApp(
      home: Scaffold(
        body: HomeHeroBanner(
          song: null,
          onPlay: _noop,
        ),
      ),
    );
  }

  double bannerWidth(WidgetTester tester) {
    final clip = find.byWidgetPredicate(
      (w) =>
          w is ClipRRect &&
          (w.borderRadius == BorderRadius.circular(24.0) ||
              w.borderRadius == BorderRadius.circular(28.0)),
    );
    return tester.getSize(clip.first).width;
  }

  testWidgets('手机模式：Banner 全宽', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildBanner());
    await tester.pump();
    // 手机宽 390，Banner 占满。
    expect(bannerWidth(tester), closeTo(390, 1));
  });

  testWidgets('平板模式：Banner 宽度受限并居中（非全宽）', (tester) async {
    // 平板横屏 1280×800。
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AppLayoutSettings.tabletMode.value = true;

    await tester.pumpWidget(buildBanner());
    await tester.pump();

    final width = bannerWidth(tester);
    debugPrint('平板 Banner 宽度: $width');
    // 平板横屏 1280 宽，Banner 不应占满全宽（限制在平板友好宽度内）。
    expect(width, lessThan(1280));
    expect(width, greaterThan(400), reason: 'Banner 应仍是显著的大视觉');
  });
}
