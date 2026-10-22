import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/feiniu/access_code_service.dart';
import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/state/settings_fn_state.dart';

/// 构造一个用拦截器短路返回指定状态码的 Dio（不真正发网络请求）
Dio _mockDio({
  required int status,
  void Function(RequestOptions)? onRequest,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call(options);
        handler.resolve(
          Response<dynamic>(requestOptions: options, statusCode: status),
        );
      },
    ),
  );
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppFnConnectionSettings.resetForTest();
  });

  group('accessCodeHeaders', () {
    test('未设置安全码时返回空', () {
      expect(FeiNiuApiClient.accessCodeHeaders(), isEmpty);
    });

    test('已设置时返回 base64 编码 + source', () async {
      await AppFnConnectionSettings.setAccessCode('hello');
      final headers = FeiNiuApiClient.accessCodeHeaders();
      expect(headers['x-access-code'], base64.encode(utf8.encode('hello')));
      expect(headers['x-access-source'], 'app');
    });
  });

  group('requiresAccessCode', () {
    test('401 → 需要安全码', () async {
      AccessCodeService.instance.setDioForTest(_mockDio(status: 401));
      expect(
        await AccessCodeService.instance.requiresAccessCode('https://x'),
        isTrue,
      );
    });

    test('204 → 不需要安全码', () async {
      AccessCodeService.instance.setDioForTest(_mockDio(status: 204));
      expect(
        await AccessCodeService.instance.requiresAccessCode('https://x'),
        isFalse,
      );
    });
  });

  group('verify', () {
    test('204 → 有效', () async {
      AccessCodeService.instance.setDioForTest(_mockDio(status: 204));
      expect(
        await AccessCodeService.instance.verify('https://x', 'code'),
        isTrue,
      );
    });

    test('401/403/429 → 无效', () async {
      for (final status in [401, 403, 429]) {
        AccessCodeService.instance.setDioForTest(_mockDio(status: status));
        expect(
          await AccessCodeService.instance.verify('https://x', 'code'),
          isFalse,
          reason: 'status $status 应判定为访问码错误',
        );
      }
    });

    test('请求头携带 base64 安全码', () async {
      RequestOptions? captured;
      AccessCodeService.instance.setDioForTest(
        _mockDio(status: 204, onRequest: (o) => captured = o),
      );
      await AccessCodeService.instance.verify('https://x', 'secret');
      expect(captured, isNotNull);
      expect(
        captured!.headers['x-access-code'],
        base64.encode(utf8.encode('secret')),
      );
      expect(captured!.headers['x-access-source'], 'app');
    });

    test('中继模式携带 Cookie: mode=relay', () async {
      RequestOptions? captured;
      AccessCodeService.instance.setDioForTest(
        _mockDio(status: 204, onRequest: (o) => captured = o),
      );
      await AccessCodeService.instance.verify('https://x', 'secret', isRelay: true);
      expect(captured!.headers['Cookie'], contains('mode=relay'));
    });

    test('requiresAccessCode 中继模式携带 Cookie: mode=relay', () async {
      RequestOptions? captured;
      AccessCodeService.instance.setDioForTest(
        _mockDio(status: 401, onRequest: (o) => captured = o),
      );
      expect(
        await AccessCodeService.instance.requiresAccessCode(
          'https://x',
          isRelay: true,
        ),
        isTrue,
      );
      expect(captured!.headers['Cookie'], contains('mode=relay'));
    });
  });

  group('状态持久化', () {
    test('setAccessCode 持久化并可重载', () async {
      await AppFnConnectionSettings.setAccessCode('abc123');
      expect(AppFnConnectionSettings.accessCode, 'abc123');

      AppFnConnectionSettings.resetForTest();
      await AppFnConnectionSettings.ensureLoaded();
      expect(AppFnConnectionSettings.accessCode, 'abc123');
    });

    test('setAccessCode(null) 清除', () async {
      await AppFnConnectionSettings.setAccessCode('abc123');
      await AppFnConnectionSettings.setAccessCode(null);
      expect(AppFnConnectionSettings.accessCode, isNull);
    });

    test('clearConnection 清除安全码', () async {
      await AppFnConnectionSettings.setAccessCode('abc123');
      await AppFnConnectionSettings.clearConnection();
      expect(AppFnConnectionSettings.accessCode, isNull);
    });
  });
}
