import 'package:flutter/material.dart';

import '../../../app/state/settings_layout_state.dart';
import '../../../app/tv/tv_layout.dart';

/// 首页模块小标题行 — 「标题」+ 右侧可选「全部 ›」。
///
/// 相比旧 _HomeSectionCard 的 18/w700 大标题，这里改小改轻，
/// 让模块标题只作为路标，把视觉重点让给下方的封面内容。
class HomeSectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onViewAll;

  /// 标题行右侧额外控件（如收藏的「播放全部」按钮）。放在「全部」之前。
  final Widget? trailing;

  const HomeSectionHeader({
    super.key,
    required this.title,
    this.onViewAll,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = AppLayoutSettings.tvMode.value
        ? TvLayout.uiScale(context)
        : 1.0;
    return Padding(
      padding: EdgeInsets.only(bottom: 8 * scale),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 17 * scale,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          if (trailing != null) ...[trailing!, SizedBox(width: 4 * scale)],
          if (onViewAll != null)
            TextButton(
              onPressed: onViewAll,
              style: TextButton.styleFrom(
                padding: EdgeInsets.symmetric(
                  horizontal: 4 * scale,
                  vertical: 2 * scale,
                ),
                minimumSize: Size(0, 32 * scale),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '全部',
                    style: TextStyle(
                      fontSize: 13 * scale,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18 * scale,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
