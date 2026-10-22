import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_connection_probe_service.dart';

/// 探测的鉴权校验（fnProbeResponseUsable）：
///
/// 登录后探测携带当前 token，候选地址必须通过带鉴权的 API 请求才算「可用」。
/// 否则 TCP 可达但 token 被拒的地址（如切到与登录凭据不匹配的服务器 IP，
/// 日志表现为 INVALID TOKEN / 401）会被误选为连接，导致后续全部请求失败。
/// 登录前无 token 时退化为纯 TCP 可达性探测（一律视为可用）。
void main() {
  Response<dynamic> r(int status, [Map<String, dynamic>? data]) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: 'http://x'),
        statusCode: status,
        data: data,
      );

  /// 带 Location 头的响应（构造探测候选返回的 3xx）。
  Response<dynamic> rWithLocation(
    int status,
    String location, {
    String requestUrl = 'http://[2001:db8::1]:5666/music/api/v1/track/list',
  }) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: requestUrl),
        statusCode: status,
        headers: Headers.fromMap({
          'location': [location],
        }),
        data: null,
      );

  group('fnProbeResponseUsable', () {
    test('未鉴权检查（登录前 TCP-only）时一律可用', () {
      expect(fnProbeResponseUsable(r(200), authChecked: false), isTrue);
      expect(fnProbeResponseUsable(r(401), authChecked: false), isTrue);
      expect(fnProbeResponseUsable(r(500), authChecked: false), isTrue);
    });

    test('HTTP 401/403 → 不可用（token 被拒）', () {
      expect(fnProbeResponseUsable(r(401), authChecked: true), isFalse);
      expect(fnProbeResponseUsable(r(403), authChecked: true), isFalse);
    });

    test('HTTP 5xx → 不可用（服务端错误）', () {
      expect(fnProbeResponseUsable(r(500), authChecked: true), isFalse);
      expect(fnProbeResponseUsable(r(503), authChecked: true), isFalse);
    });

    test('业务码 0 → 可用', () {
      expect(
        fnProbeResponseUsable(r(200, {'code': 0}), authChecked: true),
        isTrue,
      );
    });

    test('业务码非 0（如 INVALID TOKEN）→ 不可用', () {
      expect(
        fnProbeResponseUsable(r(200, {'code': 401}), authChecked: true),
        isFalse,
      );
      expect(
        fnProbeResponseUsable(
          r(200, {'code': -1, 'msg': 'INVALID TOKEN'}),
          authChecked: true,
        ),
        isFalse,
      );
    });

    test('200 且无业务码 → 可用（兜底）', () {
      expect(fnProbeResponseUsable(r(200), authChecked: true), isTrue);
    });

    test('HTTP 被强制跳转 HTTPS（302 → https）：未鉴权也判不可用', () {
      final resp = rWithLocation(
        302,
        'https://[2001:db8::1]:5667/music/api/v1/track/list',
      );
      expect(fnProbeResponseUsable(resp, authChecked: false), isFalse);
    });

    test('HTTP 被强制跳转 HTTPS（302 → https）：已鉴权也判不可用', () {
      final resp = rWithLocation(
        302,
        'https://[2001:db8::1]:5667/music/api/v1/track/list',
      );
      expect(fnProbeResponseUsable(resp, authChecked: true), isFalse);
    });

    test('302 但 Location 为同协议 http → 不误伤（按原逻辑）', () {
      final sameScheme = rWithLocation(302, 'http://[2001:db8::1]:5666/x');
      expect(fnProbeResponseUsable(sameScheme, authChecked: false), isTrue);
      expect(fnProbeResponseUsable(sameScheme, authChecked: true), isTrue);
    });

    test('无 Location 的 3xx → 不误伤（按原逻辑）', () {
      expect(fnProbeResponseUsable(r(302), authChecked: false), isTrue);
      expect(fnProbeResponseUsable(r(302), authChecked: true), isTrue);
    });
  });

  group('fnHttpToHttpsRedirectTarget', () {
    test('绝对 https Location → 返回跳转目标', () {
      final resp = rWithLocation(
        302,
        'https://[2001:db8::1]:5667/music/api/v1/track/list',
      );
      expect(
        fnHttpToHttpsRedirectTarget(resp),
        'https://[2001:db8::1]:5667/music/api/v1/track/list',
      );
    });

    test('相对 Location → 相对原请求 URL 解析（保持原 scheme）', () {
      // https 原请求 + 相对 Location：解析后仍是 https，命中 HTTPS 跳转判定
      final httpsResp = rWithLocation(
        302,
        '/other',
        requestUrl: 'https://[2001:db8::1]:5667/music/api/v1/track/list',
      );
      expect(
        fnHttpToHttpsRedirectTarget(httpsResp),
        'https://[2001:db8::1]:5667/other',
      );
      // http 原请求 + 相对 Location：解析后仍为 http，不是 HTTPS 跳转
      final httpResp = rWithLocation(302, '/other');
      expect(fnHttpToHttpsRedirectTarget(httpResp), isNull);
    });

    test('同协议 http 跳转 / 非 3xx / 无 Location → null', () {
      final httpJump = rWithLocation(302, 'http://[2001:db8::1]:5666/y');
      expect(fnHttpToHttpsRedirectTarget(httpJump), isNull);

      final not3xx = rWithLocation(
        200,
        'https://[2001:db8::1]:5667/y',
      );
      expect(fnHttpToHttpsRedirectTarget(not3xx), isNull);

      expect(fnHttpToHttpsRedirectTarget(r(302)), isNull);
    });
  });

  group('fnHttpsRedirectBase', () {
    test('authChecked=true：剥掉探测路径 /music/api/v1/track/list', () {
      expect(
        fnHttpsRedirectBase(
          'https://[2001:db8::1]:5667'
          '/music/api/v1/track/list',
          authChecked: true,
        ),
        'https://[2001:db8::1]:5667',
      );
    });

    test('authChecked=false：根路径跳转仅去末尾斜杠', () {
      expect(
        fnHttpsRedirectBase(
          'https://[2001:db8::1]:5667/',
          authChecked: false,
        ),
        'https://[2001:db8::1]:5667',
      );
    });

    test('跳转目标不带探测路径时不被误剥', () {
      expect(
        fnHttpsRedirectBase('https://h:5667/', authChecked: true),
        'https://h:5667',
      );
    });
  });
}
