import 'package:flutter/material.dart';

/// 可点击的数量显示文本
///
/// [onTap] 为 null 时与原样 [Text] 完全一致（零视觉变化）；
/// 非 null 时包一层 InkWell，并在文本右侧追加一个小箭头提示可点击。
class LoadMoreCountText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final VoidCallback? onTap;

  const LoadMoreCountText({
    super.key,
    required this.text,
    this.style,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: style);
    final callback = onTap;
    if (callback == null) return label;
    return InkWell(
      onTap: callback,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            label,
            const SizedBox(width: 2),
            Icon(
              Icons.expand_more_rounded,
              size: 14,
              color: style?.color,
            ),
          ],
        ),
      ),
    );
  }
}
