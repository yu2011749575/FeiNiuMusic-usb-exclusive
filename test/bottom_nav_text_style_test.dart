import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_glass_state.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/components/common/app_default_text_style.dart';
import 'package:feiniu_music/components/layout/modern_navigation_bar.dart';

/// 外壳层共享底栏没有 Material 祖先（见 app_router.dart 的
/// _PrimaryNavigationShell：底栏与 IndexedStack 同为 Stack 的子节点），
/// MaterialApp 会把自带的兜底文字样式（黄色双下划线 + monospace）作为
/// DefaultTextStyle 注入，底栏文字因此带下划线。
List<TextStyle> _allTextStyles(WidgetTester tester) {
  final styles = <TextStyle>[];
  for (final element in find.byType(Text).evaluate()) {
    final text = element.widget as Text;
    final inherited = DefaultTextStyle.of(element).style;
    final own = text.style;
    styles.add(own == null ? inherited : inherited.merge(own));
  }
  return styles;
}

void _expectNoUnderline(WidgetTester tester, String reason) {
  final styles = _allTextStyles(tester);
  expect(styles, isNotEmpty, reason: '底栏应渲染出 tab 文字');
  for (final style in styles) {
    expect(
      style.decoration ?? TextDecoration.none,
      TextDecoration.none,
      reason: reason,
    );
    expect(style.decorationStyle, isNot(TextDecorationStyle.double));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppGlassSettings.liquidGlassEnabled.value = false;
    AppLayoutSettings.resetForTest();
  });

  /// 复刻外壳层结构：Stack 直接挂在 MaterialApp 下，没有 Scaffold/Material。
  /// builder 与 app.dart 一致，套一层 AppDefaultTextStyle。
  Widget shellHarness() {
    return MaterialApp(
      builder: (context, child) =>
          AppDefaultTextStyle(child: child ?? const SizedBox.shrink()),
      home: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ModernNavigationBar(onTap: (_) {}),
          ),
        ],
      ),
    );
  }

  for (final glass in <bool>[false, true]) {
    testWidgets('外壳层底栏文字不带兜底下划线（玻璃=$glass）', (tester) async {
      AppGlassSettings.liquidGlassEnabled.value = glass;

      await tester.pumpWidget(shellHarness());
      await tester.pump();

      _expectNoUnderline(
        tester,
        '底栏文字不应带下划线（MaterialApp 兜底样式为黄色双下划线）',
      );
    });
  }

  testWidgets('底栏组件自身不依赖外部 Material 祖先', (tester) async {
    // 不套 AppDefaultTextStyle：验证组件自己就提供了基准文字样式。
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ModernNavigationBar(onTap: (_) {}),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    _expectNoUnderline(tester, '底栏组件应在任何挂载位置都不带下划线');
  });

  testWidgets('AppDefaultTextStyle 不把 monospace 兜底字体传给文字', (tester) async {
    late TextStyle inherited;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppDefaultTextStyle(child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (context) {
            inherited = DefaultTextStyle.of(context).style;
            return const Text('hello');
          },
        ),
      ),
    );
    await tester.pump();

    expect(inherited.fontFamily, isNot('monospace'));
    expect(inherited.decoration ?? TextDecoration.none, TextDecoration.none);
  });
}
