import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/utils/app_navigator.dart';
import '../../app/tv/tv_remote_actions.dart';

/// TV 根焦点域：包裹整个应用内容，提供遥控器方向键遍历 + 快捷键。
///
/// 只在 `tvEnabled` 时由 `MaterialApp.builder` 安装；手机端完全不参与。
///
/// 焦点移动用**纯几何定位**：方向键按下时收集整棵焦点树里所有可聚焦节点
/// 的屏幕矩形，按当前焦点位置在指定方向上找「投影重叠 + 距离最近」的目标
/// 并用 `requestFocus` 聚焦（该调用自带滚入视野，能进入离屏的列表行）。
/// 弃用 Flutter 默认的 ReadingOrder policy——它在多层嵌套列表/横向滑动区
/// 布局里移动焦点不可靠，容易跳过列表行或误跳出。
///
/// 边缘兜底：左方向移不动 → 聚焦整棵应用最左侧的可聚焦项（侧边栏）；
/// 右方向移不动 → 打开播放页。
class TvFocusScope extends StatefulWidget {
  final Widget child;

  const TvFocusScope({super.key, required this.child});

  @override
  State<TvFocusScope> createState() => _TvFocusScopeState();
}

class _TvFocusScopeState extends State<TvFocusScope> {
  @override
  void initState() {
    super.initState();
    // Touch 分类设备（TV 盒子、模拟器）上 Material 默认不显示焦点高亮；
    // 强制传统模式让主题 focusColor 在所有设备上渲染。
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }

  @override
  void dispose() {
    // 退出 TV 模式时复位为 touch 策略，避免手机端残留传统焦点高亮。
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    super.dispose();
  }

  /// 收集整棵焦点树里所有可聚焦节点及其全局矩形。
  /// 只取可见（有 RenderBox）、可聚焦、参与遍历的节点。
  List<(FocusNode, Rect)> _collectFocusable() {
    final result = <(FocusNode, Rect)>[];
    final seen = <FocusNode>{};
    void walk(FocusNode node) {
      for (final d in node.descendants) {
        if (!seen.add(d)) continue;
        if (d.canRequestFocus && !d.skipTraversal && d.context != null) {
          final ro = d.context!.findRenderObject();
          if (ro is RenderBox && ro.hasSize && ro.attached) {
            final global = ro.localToGlobal(Offset.zero);
            result.add((
              d,
              global & ro.size,
            ));
          }
        }
        walk(d);
      }
    }

    walk(FocusManager.instance.rootScope);
    return result;
  }

  /// 在当前焦点沿 [dir] 方向找最近的可聚焦目标。
  ///
  /// 纯几何：候选目标需落在当前节点的投影带内（水平移动要求纵向投影重叠，
  /// 垂直移动要求横向投影重叠），再取中心距最近者。这样——
  /// - 左右键在四宫格 2×2 内横向切换；
  /// - 上下键在歌曲列表内逐行下移；
  /// - 向右越过四宫格能一路进到三列列表/右侧内容；
  /// - 向左越过边缘落到侧边栏。
  FocusNode? _moveFocus(FocusNode current, TraversalDirection dir) {
    final all = _collectFocusable();
    if (all.isEmpty) return null;
    final curRo = current.context?.findRenderObject();
    if (curRo is! RenderBox || !curRo.hasSize || !curRo.attached) return null;
    final curRect = curRo.localToGlobal(Offset.zero) & curRo.size;
    final curCenter = curRect.center;

    FocusNode? best;
    double bestDist = double.infinity;

    for (final (node, rect) in all) {
      if (identical(node, current)) continue;
      final targetCenter = rect.center;

      final dx = targetCenter.dx - curCenter.dx;
      final dy = targetCenter.dy - curCenter.dy;

      final bool inDirection = switch (dir) {
        TraversalDirection.left => dx < 0,
        TraversalDirection.right => dx > 0,
        TraversalDirection.up => dy < 0,
        TraversalDirection.down => dy > 0,
      };
      if (!inDirection) continue;

      // 投影重叠判定：水平移动需纵向投影重叠（或贴近），垂直移动需横向
      // 投影重叠。容忍 4px 的间隙，避免因圆角/间距边界卡死。
      final bool overlaps = switch (dir) {
        TraversalDirection.left ||
        TraversalDirection.right =>
          _rangesOverlap(curRect.top, curRect.bottom, rect.top, rect.bottom),
        TraversalDirection.up || TraversalDirection.down =>
          _rangesOverlap(curRect.left, curRect.right, rect.left, rect.right),
      };
      if (!overlaps) continue;

      final dist = (targetCenter - curCenter).distance;
      if (dist < bestDist) {
        bestDist = dist;
        best = node;
      }
    }
    return best;
  }

  bool _rangesOverlap(double a0, double a1, double b0, double b1) {
    return (a0 - 4) <= b1 && (b0 - 4) <= a1;
  }

  void _moveOrEdge(TraversalDirection dir) {
    final current = FocusManager.instance.primaryFocus;
    if (current == null) return;
    final target = _moveFocus(current, dir);
    if (target != null) {
      _focusAndReveal(target);
      return;
    }
    // 移不动 → 边缘动作
    if (dir == TraversalDirection.left) {
      final leftmost = _focusLeftmost();
      if (leftmost == null) return;
      _focusAndReveal(leftmost);
    } else if (dir == TraversalDirection.right) {
      AppNavigator.pushNamed(AppRoutes.player);
    }
  }

  /// 聚焦 [node] 并把它滚入视野。
  ///
  /// requestFocus 本身不会滚动；离屏目标（如歌曲列表深处未 build 的行，
  /// 或横向列表边缘外）必须手动 ensureVisible 才能真实显示并让用户看到
  /// 焦点落在哪。取目标 RenderBox 的全局矩形，沿其祖先 Scrollable 滚动。
  void _focusAndReveal(FocusNode node) {
    node.requestFocus();
    final ro = node.context?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return;
    final ctx = node.context!;
    if (ctx.mounted) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  /// 整棵应用最左侧的可聚焦项（即侧边栏首个菜单项）。
  /// 侧栏在 TV 模式下始终钉在左缘，因此「向左到尽头」即「聚焦侧边栏」。
  FocusNode? _focusLeftmost() {
    final all = _collectFocusable();
    if (all.isEmpty) return null;
    FocusNode? leftmost;
    var minDx = double.infinity;
    for (final (node, rect) in all) {
      if (rect.left < minDx) {
        minDx = rect.left;
        leftmost = node;
      }
    }
    return leftmost;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: buildTvShortcuts(),
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: TvRemoteActions(
          // TV 方向键：纯几何移动。移不动时左边缘聚焦侧边栏、右边缘开播放页。
          // 输入框/滑块有更内层的 Shortcuts，聚焦时会先处理方向键，不会触发这里。
          child: Actions(
            actions: <Type, Action<Intent>>{
              DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
                onInvoke: (intent) {
                  _moveOrEdge(intent.direction);
                  // 返回非 null 表示已处理：手动移动已经完成，避免框架对同一
                  // Intent 再做一次默认遍历。
                  return true;
                },
              ),
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
