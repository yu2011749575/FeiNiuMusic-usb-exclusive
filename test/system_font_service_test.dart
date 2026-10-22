import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/system_font_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.feiniu.music/system_fonts');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SystemFontService.resetForTest();
  });

  test('系统字体会去重、去空并按名称排序', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getFamilies');
          return <String>[' PingFang SC ', 'Arial', '', 'Arial'];
        });

    expect(await SystemFontService.availableFamilies(), <String>[
      'Arial',
      'PingFang SC',
    ]);
  });

  test('字体通道不可用时安全返回空列表', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'unavailable');
        });

    expect(await SystemFontService.availableFamilies(), isEmpty);
  });
}
