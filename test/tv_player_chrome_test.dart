import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/router/app_router.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/components/layout/tablet_layout_host.dart';
import 'package:feiniu_music/components/player/mini_player/mini_player_bar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() => AppLayoutSettings.resetForTest());

  Widget buildHost() {
    final navKey = GlobalKey<NavigatorState>();
    return MaterialApp(
      home: TabletLayoutHost(
        navigatorKey: navKey,
        child: Navigator(
          key: navKey,
          initialRoute: AppRoutes.home,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('内容')),
          ),
        ),
      ),
    );
  }

  bool sideMenuInvisible(WidgetTester tester) {
    // 直接找我们加的「播放页隐藏」IgnorePointer（带 key），读它的 ignoring。
    // 不要用 find.ancestor(IgnorePointer)：MaterialApp 路由转场也会包一层
    // IgnorePointer，会干扰匹配。
    final hide = tester.widget<IgnorePointer>(
      find.byKey(const ValueKey('tv-player-hide-sidebar')),
    );
    return hide.ignoring;
  }

  testWidgets('非 TV：播放页激活也不隐藏侧栏', (tester) async {
    await tester.pumpWidget(buildHost());
    await tester.pump();
    AppLayoutSettings.playerRouteActive.value = true;
    await tester.pump();
    expect(sideMenuInvisible(tester), isFalse);
  });

  testWidgets('TV + 播放页激活 → 侧栏被隐藏且内容区铺满全屏（左无偏移），返回还原',
      (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await tester.pumpWidget(buildHost());
    await tester.pump();
    expect(sideMenuInvisible(tester), isFalse);

    AppLayoutSettings.playerRouteActive.value = true;
    await tester.pump();
    expect(sideMenuInvisible(tester), isTrue);

    // 隐藏后内容区铺满全屏：内容偏移 Padding 的 left 为 0，不再留左侧空白。
    final offsetPad = tester.widget<Padding>(
      find.byKey(const ValueKey('tv-player-content-offset')),
    );
    final leftOffset = (offsetPad.padding as EdgeInsets).left;
    expect(leftOffset, 0);

    // 返回后还原
    AppLayoutSettings.playerRouteActive.value = false;
    await tester.pump();
    expect(sideMenuInvisible(tester), isFalse);
  });

  testWidgets('平板/TV 迷你播放器不覆盖侧边栏（侧栏底部设置入口可点击）',
      (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await tester.pumpWidget(buildHost());
    await tester.pump();

    // 迷你播放器全宽时 left 应为 drawerWidth（=侧边栏宽度），
    // 不覆盖左侧侧边栏区域。
    final miniPlayer = tester.widget<Positioned>(
      find.ancestor(
        of: find.byType(MiniPlayerBar),
        matching: find.byType(Positioned),
      ).first,
    );
    // 侧边栏宽度：TV 模式 (width*0.28).clamp(320,360)。测试窗口默认 800×600，
    // width=800 → 800*0.28=224 → clamp 到 320。
    expect(miniPlayer.left, 320);
  });
}
