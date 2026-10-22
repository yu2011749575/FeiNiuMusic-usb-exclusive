import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_state.dart'; // AppLayoutSettings / AppThemeSettings
import 'package:feiniu_music/pages/settings/notification_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });

  tearDown(() => AppLayoutSettings.resetForTest());

  testWidgets('总开关关闭时不显示「应用外通知」子开关', (tester) async {
    await AppLayoutSettings.setTrackChangeNotify(false);
    await tester.pumpWidget(const MaterialApp(home: NotificationSettingsPage()));
    // 页面 initState 异步加载设置 + 能力探测，用有限次 pump 让异步完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('应用外通知'), findsNothing);
  });

  testWidgets('总开关开启时显示「应用外通知」子开关', (tester) async {
    await AppLayoutSettings.setTrackChangeNotify(true);
    await tester.pumpWidget(const MaterialApp(home: NotificationSettingsPage()));
    // 页面 initState 异步加载设置 + 能力探测，用有限次 pump 让异步完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('应用外通知'), findsOneWidget);
  });
}
