import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_lyric/core/lyric_style.dart';
import 'package:flutter_lyric/render/lyric_layout.dart';
import 'package:flutter_lyric/render/lyric_painter.dart';
import 'package:flutter_lyric/widgets/lyric_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造与应用歌词页一致的 LyricStyle。
LyricStyle _appStyle() {
  return LyricStyle(
    textStyle: const TextStyle(
      fontSize: 16,
      color: Colors.grey,
      height: 1.3,
    ),
    activeStyle: const TextStyle(
      fontSize: 20,
      color: Colors.white,
      fontWeight: FontWeight.w700,
      height: 1.3,
    ),
    translationStyle: const TextStyle(
      color: Colors.grey,
      fontSize: 13.6,
      height: 1.2,
    ),
    lineTextAlign: TextAlign.center,
    contentAlignment: CrossAxisAlignment.center,
    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    lineGap: 14,
    translationLineGap: 8,
    selectionAnchorPosition: 0.5,
    activeAnchorPosition: 0.5,
    selectionAlignment: MainAxisAlignment.center,
    activeAlignment: MainAxisAlignment.center,
    scrollDuration: const Duration(milliseconds: 380),
    scrollCurve: Curves.easeOutCubic,
    selectedColor: Colors.white,
    selectedTranslationColor: Colors.white,
    selectionAutoResumeDuration: const Duration(milliseconds: 200),
    activeAutoResumeDuration: const Duration(days: 365),
  );
}

LyricModel _model(int lineCount, {bool withTranslation = false}) {
  return LyricModel(
    lines: List.generate(
      lineCount,
      (i) => LyricLine(
        start: Duration(seconds: i * 5),
        text: '第 ${i + 1} 行歌词内容测试',
        translation: withTranslation ? 'Translation $i' : null,
      ),
    ),
  );
}

LyricLayout _layout(LyricModel model) {
  return LyricLayout.compute(
    model,
    _appStyle(),
    const Size(400, 612),
  );
}

void main() {
  group('lineOffsetY 首行定位', () {
    test('无翻译、行数不足时第 0 行锚点对齐视口锚点（返回负值，居中而非顶置）',
        () {
      final layout = _layout(_model(5));
      final offset = layout.lineOffsetY(
        0,
        0,
        layout.selectionAnchorPosition,
        _appStyle().selectionAlignment,
      );
      // 行 0 高度约 26px，锚点 306 → 负偏移，内容下移、首行居中
      expect(offset, lessThan(0));
      // 旧实现返回 -contentPadding.top = -12，仅首行居中；新实现应远小于 -12
      expect(offset, lessThan(-12));
    });

    test('第 0 行处于视口顶部时不再返回 -contentPadding.top（回归断言）', () {
      final layout = _layout(_model(4));
      final offset = layout.lineOffsetY(
        0,
        0,
        layout.selectionAnchorPosition,
        _appStyle().selectionAlignment,
      );
      // 旧实现：anchorPosition(306) < 0*?+contentPadding.top(12) 不成立 → -12
      // 新实现：始终 indexStartY - anchorPosition → 远小于 -12（真正居中）
      expect(offset, lessThan(-100));
    });

    test('行高足够时（逐字大字）仍按锚点居中', () {
      // 用 activeHeight 较大的样式模拟逐字行，确认居中语义不被破坏
      final style = _appStyle().copyWith(
        textStyle: const TextStyle(fontSize: 100, color: Colors.grey),
        activeStyle: const TextStyle(
          fontSize: 120,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      );
      final layout = LyricLayout.compute(
        _model(3),
        style,
        const Size(400, 612),
      );
      final offset = layout.lineOffsetY(
        0,
        0,
        layout.selectionAnchorPosition,
        style.selectionAlignment,
      );
      expect(offset, lessThan(0));
    });
  });

  group('lineOffsetY 后续行', () {
    test('行索引居中定位随行高累计', () {
      final layout = _layout(_model(20));
      final offset = layout.lineOffsetY(
        10,
        10,
        layout.selectionAnchorPosition,
        _appStyle().selectionAlignment,
      );
      // 第 10 行累计高度应越过锚点 → 正偏移
      expect(offset, greaterThan(0));
    });
  });

  testWidgets('LyricView 首行歌词渲染在视口中部而非顶部（端到端）',
      (tester) async {
    final controller = LyricController();
    addTearDown(controller.dispose);
    // 4 行、无翻译、无逐字词——模拟行数不足的普通歌词
    controller.loadLyricModel(_model(4));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 612,
            child: LyricView(controller: controller, style: _appStyle()),
          ),
        ),
      ),
    );
    // 布局计算在 post-frame 后执行
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 直接检查渲染出的 CustomPaint 的 scrollY 状态（由 scrollYNotifier 驱动）。
    // LyricView 状态持有 scrollYNotifier；通过渲染树无法直接读私有字段，
    // 改用「首行文本的可见位置」断言：滚动为负（内容下移）时首行应出现在
    // 视口上半部偏中位置，而非紧贴顶部。
    final paintRenderObjects = tester
        .renderObjectList<RenderCustomPaint>(find.byType(CustomPaint))
        .where((ro) => ro.painter is LyricPainter)
        .toList();
    expect(paintRenderObjects, isNotEmpty, reason: '应找到 LyricPainter 渲染节点');
    final painter = paintRenderObjects.first.painter as LyricPainter;
    final scrollY = painter.scrollY;
    expect(scrollY, lessThan(-100), reason: '首行应居中而非顶置（scrollY=$scrollY）');
  });
}
