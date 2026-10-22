import 'package:flutter/widgets.dart';

/// 全局根 Navigator key。
///
/// 挂在 MaterialApp.navigatorKey 上。供无 BuildContext 的服务层
/// （如 PlayerService）在漫游失败等场景通过 currentContext 弹全局 toast。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
