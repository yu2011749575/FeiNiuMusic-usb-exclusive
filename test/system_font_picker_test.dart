import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/system_font_service.dart';
import 'package:feiniu_music/components/common/system_font_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.feiniu.music/system_fonts');

  setUp(() {
    SystemFontService.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <String>['Arial']);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SystemFontService.resetForTest();
  });

  testWidgets('可从本机字体列表选择并立即显示', (tester) async {
    String selected = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SystemFontPicker(
            value: selected,
            onChanged: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('已读取 1 个本机字体'), findsOneWidget);
    await tester.tap(find.text('跟随系统').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arial'));
    await tester.pumpAndSettle();

    expect(selected, 'Arial');
    expect(find.text('Arial'), findsNWidgets(2));
  });
}
