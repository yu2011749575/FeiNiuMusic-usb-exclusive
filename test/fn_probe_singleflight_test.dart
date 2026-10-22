import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_connection_probe_service.dart';
import 'package:feiniu_music/app/services/feiniu/fn_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FnConnectionProbeService service;

  ConnectionProbeResult result(String url) =>
      ConnectionProbeResult(serverUrl: url, probeMethod: 'test');

  setUp(() {
    service = FnConnectionProbeService.instance;
    service.resetForTest();
  });

  test('同 FNID 并发探测复用同一在途请求，只执行一次 start', () async {
    var startCalls = 0;
    final completer = Completer<ConnectionProbeResult>();

    final first = service.joinOrStartProbeForTest(
      fnId: 'myid',
      start: () {
        startCalls++;
        return completer.future;
      },
    );

    // 探测进行中再次发起同 FNID 调用 → 复用，不再次 start
    final second = service.joinOrStartProbeForTest(
      fnId: 'myid',
      start: () {
        startCalls++;
        return completer.future;
      },
    );

    expect(identical(first, second), isTrue,
        reason: '同 FNID 应共享同一 Future');
    expect(startCalls, 1, reason: '并发调用只应执行一次 start');

    // 完成探测后，在途标记清空，可再次发起
    completer.complete(result('https://a'));
    await first;
    expect(service.isProbing.value, isFalse);

    final after = service.joinOrStartProbeForTest(
      fnId: 'myid',
      start: () async => result('https://b'),
    );
    expect((await after).serverUrl, 'https://b');
  });

  test('探测进行中抛异常也不会卡死在途状态', () async {
    var startCalls = 0;
    final completer = Completer<ConnectionProbeResult>();

    final first = service.joinOrStartProbeForTest(
      fnId: 'myid',
      start: () {
        startCalls++;
        return completer.future;
      },
    );

    // 先挂上监听，再让探测失败（避免 unhandled async error）
    final expectation = expectLater(first, throwsException);
    completer.completeError(Exception('探测失败'));
    await expectation;
    expect(service.isProbing.value, isFalse);

    // 失败后再次发起应正常执行（start 重新计数）
    final retry = service.joinOrStartProbeForTest(
      fnId: 'myid',
      start: () async => result('https://retry'),
    );
    expect(startCalls, 1);
    expect((await retry).serverUrl, 'https://retry');
  });

  test('不同 FNID 并发仍被拒绝', () async {
    final completer = Completer<ConnectionProbeResult>();
    final first = service.joinOrStartProbeForTest(
      fnId: 'myid',
      start: () => completer.future,
    );

    await expectLater(
      () => service.joinOrStartProbeForTest(
        fnId: 'other',
        start: () async => result('https://other'),
      ),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('探测正在进行中'),
      )),
    );

    completer.complete(result('https://a'));
    await first;
  });
}
