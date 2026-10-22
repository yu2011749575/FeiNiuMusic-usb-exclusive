import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../navigator_key.dart';

/// 后台播放保护：一次性提示用户关闭电池优化（audio_service 官方 FAQ 对
/// 小米/华为等 OEM 的标准处方）。
///
/// 实锤依据（2026-09-26 04:42 小米15/HyperOS）：audio_service 的
/// mediaPlayback 前台服务 `isForeground=true` 正常运行，但 MIUI 仍在
/// 切后台 ~45s 后冻结整个进程——Kotlin 解码日志与 native 泵同时静默、
/// `dumpsys media_session` 的 PlaybackState.position 定格在 32415 不再
/// 更新（通知栏进度条靠系统外推"假跑"）。仅电池优化豁免（无限制电量
/// 策略）能让 MIUI 放行。
class BatteryGuard {
  BatteryGuard._();

  static bool _checked = false;

  /// 首次播放后调用（fire-and-forget）：已豁免或已提示过则直接返回。
  static Future<void> maybePrompt() async {
    if (_checked || kIsWeb || !Platform.isAndroid) return;
    _checked = true;
    try {
      final granted = await Permission.ignoreBatteryOptimizations.isGranted;
      debugPrint('[BatteryGuard] maybePrompt enter isGranted=$granted');
      if (granted) return;
      final prefs = await SharedPreferences.getInstance();
      final prompted = prefs.getBool('battery_exempt_prompted') ?? false;
      debugPrint('[BatteryGuard] promptedBefore=$prompted');
      if (prompted) return;
      final ctx = appNavigatorKey.currentContext;
      debugPrint('[BatteryGuard] ctx=${ctx != null}');
      if (ctx == null) return;
      debugPrint('[BatteryGuard] showing dialog');
      final go = await showDialog<bool>(
        context: ctx,
        barrierDismissible: true,
        builder: (c) => AlertDialog(
          title: const Text('后台播放保护'),
          content: const Text(
            '为避免切到微信等后台约一分钟后声音被系统冻结，'
            '建议允许飞牛音乐不受电池限制。\n\n'
            'MIUI/HyperOS 若弹窗未生效，请到 系统设置 → 应用管理 → '
            '飞牛音乐 → 省电策略 中选择“无限制”。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('暂不'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('立即开启'),
            ),
          ],
        ),
      );
      debugPrint('[BatteryGuard] choice=$go');
      if (go == true) {
        await Permission.ignoreBatteryOptimizations.request();
      }
      await prefs.setBool('battery_exempt_prompted', true);
    } catch (e) {
      debugPrint('[BatteryGuard] prompt failed: $e');
    }
  }
}
