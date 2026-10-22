import 'package:flutter/material.dart';

/// App 级基础文字样式（等价于在根节点再包一层 [Material] 的 DefaultTextStyle）。
///
/// [MaterialApp] 会把自带的兜底文字样式（红色 monospace 48px + **黄色双下划线**，
/// 定义见 flutter/lib/src/material/app.dart 的 `_errorTextStyle`）作为
/// [DefaultTextStyle] 注入整棵树；只有位于 [Material]/[Scaffold] 内的 [Text]
/// 才会被换成主题样式（[Material] 内部会再包一层 `AnimatedDefaultTextStyle`）。
///
/// 外壳层悬浮组件不在任何 [Material] 内，例如：
/// - `app_router.dart` 里叠在 IndexedStack 之上的共享底部导航（[ModernNavigationBar]）；
/// - `tablet_layout_host.dart` 里平板外壳的迷你播放器。
///
/// 它们只覆盖 color/fontSize 等字段、不覆盖 `decoration`，于是会继承兜底样式的
/// 下划线，表现为底栏文字下方出现黄色横线。这里统一提供主题基准样式，
/// 任何缺少 [Material] 祖先的文字也拿到正常字体/无下划线。
class AppDefaultTextStyle extends StatelessWidget {
  final Widget child;

  const AppDefaultTextStyle({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return DefaultTextStyle(
      // 显式写明 decoration：即便上游主题（或 Material 默认）带上装饰，
      // 也不会漏给没有 Material 祖先的文字。
      style: base.copyWith(decoration: TextDecoration.none),
      child: child,
    );
  }
}
