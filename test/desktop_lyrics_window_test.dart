import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/pages/player/desktop_lyrics_window.dart';

Map<String, Object?> _payload({
  bool karaoke = false,
  String? fontFamily = 'PingFang SC',
  String position = 'fixed',
}) {
  return {
    'currentLine': '当前歌词',
    'nextLine': '下一句歌词',
    'karaoke': karaoke,
    'progress': 0.4,
    'fontFamily': fontFamily,
    'fontSize': 24.0,
    'textColor': 0xFFFFFFFF,
    'highlightColor': 0xFF59F7E7,
    'backgroundOpacity': 0.64,
    'position': position,
  };
}

/// 还原 [Text] 实际生效的样式：MaterialApp 的兜底 [DefaultTextStyle]
/// 与自身 style 合并后的结果。
List<TextStyle> _resolvedStylesOf(WidgetTester tester, String text) {
  final finder = find.text(text);
  expect(finder, findsWidgets, reason: '未找到歌词文本 $text');
  final styles = <TextStyle>[];
  for (var index = 0; index < finder.evaluate().length; index++) {
    final inherited = DefaultTextStyle.of(
      tester.element(finder.at(index)),
    ).style;
    final own = tester.widget<Text>(finder.at(index)).style;
    styles.add(own == null ? inherited : inherited.merge(own));
  }
  return styles;
}

void main() {
  testWidgets('歌词不继承 MaterialApp 兜底样式的下划线', (tester) async {
    final state = DesktopLyricsWindowState()..update(_payload());

    await tester.pumpWidget(DesktopLyricsWindow(state: state));

    for (final text in <String>['当前歌词', '下一句歌词']) {
      for (final style in _resolvedStylesOf(tester, text)) {
        expect(
          style.decoration ?? TextDecoration.none,
          TextDecoration.none,
          reason: '$text 不应带下划线（MaterialApp 兜底样式为 underline）',
        );
        expect(style.decorationStyle, isNot(TextDecorationStyle.double));
      }
    }
  });

  testWidgets('未配置字体时不使用 monospace 兜底字体', (tester) async {
    final state = DesktopLyricsWindowState()
      ..update(_payload(fontFamily: null));

    await tester.pumpWidget(DesktopLyricsWindow(state: state));

    for (final style in _resolvedStylesOf(tester, '当前歌词')) {
      expect(style.fontFamily, isNull);
    }
  });

  testWidgets('逐字歌词同样不带下划线', (tester) async {
    final state = DesktopLyricsWindowState()..update(_payload(karaoke: true));

    await tester.pumpWidget(DesktopLyricsWindow(state: state));

    for (final text in <String>['当前歌词', '下一句歌词']) {
      for (final style in _resolvedStylesOf(tester, text)) {
        expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
      }
    }
  });

  testWidgets('逐字歌词高亮层与底字完全重合（不出现两份歌词）', (tester) async {
    final state = DesktopLyricsWindowState()..update(_payload(karaoke: true));

    await tester.pumpWidget(DesktopLyricsWindow(state: state));

    // 逐字歌词渲染两层：底层整行 + 上层高亮扫光。两层必须叠在同一位置，
    // 否则看起来就是同一句歌词出现在两个地方。
    final finder = find.text('当前歌词');
    expect(finder, findsNWidgets(2), reason: '逐字歌词应渲染底字 + 高亮两层');

    final base = tester.getRect(finder.at(0));
    final highlight = tester.getRect(finder.at(1));
    expect(
      highlight.left,
      closeTo(base.left, 0.5),
      reason: '高亮层左边缘应与底字对齐（当前 left=${highlight.left}, 底字 left=${base.left}）',
    );
    expect(highlight.top, closeTo(base.top, 0.5), reason: '高亮层应与底字同一行');
    expect(highlight.width, closeTo(base.width, 0.5));
  });

  testWidgets('固定位置不接收拖动手势', (tester) async {
    final state = DesktopLyricsWindowState()..update(_payload());

    await tester.pumpWidget(DesktopLyricsWindow(state: state));

    final gesture = tester.widget<GestureDetector>(
      find.byType(GestureDetector),
    );
    expect(gesture.onPanStart, isNull);
    expect(gesture.onPanUpdate, isNull);
    expect(gesture.onPanEnd, isNull);
  });

  testWidgets('只有自由拖动模式接收拖动手势', (tester) async {
    final state = DesktopLyricsWindowState()
      ..update(_payload(position: 'free'));

    await tester.pumpWidget(DesktopLyricsWindow(state: state));

    final gesture = tester.widget<GestureDetector>(
      find.byType(GestureDetector),
    );
    expect(gesture.onPanStart, isNotNull);
    expect(gesture.onPanUpdate, isNotNull);
    expect(gesture.onPanEnd, isNotNull);
  });
}
