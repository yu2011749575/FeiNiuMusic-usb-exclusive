import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/debug_log_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 每次重置已安装的 hook，避免跨测试串状态。
    DebugLogService.instance.resetForTest();
  });

  test('开启后至少有一条「已启用」标记日志', () async {
    final s = DebugLogService.instance;
    await s.ensureLoaded();
    await s.setEnabled(true);
    expect(s.enabled.value, isTrue);
    expect(s.entries.value, isNotEmpty);
    expect(s.entries.value.first, contains('调试日志已开启'));
  });

  test('开启后 debugPrint 输出被捕获', () async {
    final s = DebugLogService.instance;
    await s.ensureLoaded();
    await s.setEnabled(true);

    debugPrint('[TestService] hello world');
    await pumpEventQueue();

    final hit = s.entries.value.where((e) => e.contains('[TestService]'));
    expect(hit, isNotEmpty, reason: '开启后 debugPrint 应被捕获');
  });

  test('关闭时 debugPrint 不被捕获', () async {
    final s = DebugLogService.instance;
    await s.ensureLoaded();
    // 默认关闭
    debugPrint('[TestService] silent');
    await pumpEventQueue();
    final hit = s.entries.value.where((e) => e.contains('silent'));
    expect(hit, isEmpty);
  });

  test('日志上限 300 条，新日志在最前', () async {
    final s = DebugLogService.instance;
    await s.ensureLoaded();
    await s.setEnabled(true);
    for (var i = 0; i < 310; i++) {
      s.add('line $i');
    }
    expect(s.entries.value.length, 300);
    expect(s.entries.value.first, contains('line 309'));
    expect(s.entries.value.last, contains('line 10'));
  });
}
