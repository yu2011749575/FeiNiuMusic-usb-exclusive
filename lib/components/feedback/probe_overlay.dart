import 'package:flutter/material.dart';

/// 探测连接加载动画浮层
///
/// 使用 [OverlayEntry] 插入到根 Overlay，全局居中展示。
/// 本浮层无固定超时关闭逻辑，完全跟随探测流程生命周期。
///
/// 用法：
/// ```dart
/// final entry = ProbeOverlay.show(context);
/// // ... 探测完成后
/// ProbeOverlay.hide(entry);
/// ```
class ProbeOverlay {
  ProbeOverlay._();

  /// 展示全局探测加载浮层
  ///
  /// 返回 [OverlayEntry] 引用，用于后续移除。
  static OverlayEntry show(BuildContext context) {
    final overlay = Overlay.of(context, rootOverlay: true);

    final entry = OverlayEntry(
      builder: (_) => const _ProbeOverlayWidget(),
    );

    overlay.insert(entry);
    return entry;
  }

  /// 隐藏探测加载浮层
  static void hide(OverlayEntry? entry) {
    entry?.remove();
  }
}

class _ProbeOverlayWidget extends StatefulWidget {
  const _ProbeOverlayWidget();

  @override
  State<_ProbeOverlayWidget> createState() => _ProbeOverlayWidgetState();
}

class _ProbeOverlayWidgetState extends State<_ProbeOverlayWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulseAnimation;
  late final Animation<double> _rotateAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _rotateAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOutCubic),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.55)
                : Colors.black.withValues(alpha: 0.35),
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 36,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 32,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 动画图标区：外环脉冲 + 内圈旋转
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // 外环脉冲
                          Transform.scale(
                            scale: _pulseAnimation.value,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.25),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                          // 半透明第二环
                          Transform.scale(
                            scale: 0.85 + 0.15 * _pulseAnimation.value,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.12),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                          // 旋转的圆弧指示器
                          Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.identity()
                              ..rotateZ(_rotateAnimation.value * 3.14159 * 2),
                            child: SizedBox(
                              width: 72,
                              height: 72,
                              child: CustomPaint(
                                painter: _ArcPainter(
                                  color: theme.colorScheme.primary,
                                  thickness: 2.5,
                                  arcLength: 0.3,
                                ),
                              ),
                            ),
                          ),
                          // 中心主进度指示器
                          SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // 主文本
                    Text(
                      '正在探测最优连接中...',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),

                    // 副文本
                    Text(
                      '正在尝试多种连接方式，请稍候',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 圆弧画笔——用于旋转的弧线指示器
class _ArcPainter extends CustomPainter {
  final Color color;
  final double thickness;
  final double arcLength; // 0~1，圆弧占整圆的比例

  const _ArcPainter({
    required this.color,
    required this.thickness,
    required this.arcLength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(
      thickness / 2,
      thickness / 2,
      size.width - thickness,
      size.height - thickness,
    );

    canvas.drawArc(
      rect,
      -3.14159 / 2, // 从顶部开始
      arcLength * 3.14159 * 2,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.thickness != thickness ||
      oldDelegate.arcLength != arcLength;
}
