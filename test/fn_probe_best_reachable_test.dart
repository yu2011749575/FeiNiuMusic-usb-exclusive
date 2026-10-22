import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_connection_probe_service.dart';
import 'package:feiniu_music/app/services/feiniu/fn_models.dart';

/// 早停并行探测（_probeBestReachable）的确定性竞态测试。
///
/// 用 [Completer] 逐条控制候选的完成时机与顺序，复现「低优先级先通、
/// 高优先级未决」等竞态：每个 completer 的 complete 是事件循环里的一个
/// 时间点，pumpEventQueue 冲刷 helper 的 Future.any 微任务，使「尚未返回」
/// 这一断言稳定可测。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = FnConnectionProbeService.instance;

  /// 构造 4 条候选（索引即优先级，0 最高），address 形如
  /// `http://candidate$i:5666`。
  List<ProbeCandidateSpec> specs(int n) => List.generate(
        n,
        (i) => ProbeCandidateSpec(
          address: 'http://candidate$i:5666',
          description: 'candidate$i',
          group: ProbeCandidateGroup.internal,
        ),
      );

  ProbeCandidateResult reachable(int i) => ProbeCandidateResult(
        address: 'http://candidate$i:5666',
        description: 'candidate$i',
        group: ProbeCandidateGroup.internal,
        isReachable: true,
      );

  ProbeCandidateResult unreachable(int i) => ProbeCandidateResult(
        address: 'http://candidate$i:5666',
        description: 'candidate$i',
        group: ProbeCandidateGroup.internal,
        isReachable: false,
        error: '连接失败',
      );

  /// 构造可注入的探测函数：返回受 [completers] 控制的 future，按 address
  /// 映射到对应 completer。
  (
    Future<
        ({
          ProbeCandidateResult? best,
          int? bestIndex,
          List<ProbeCandidateResult> decided,
        })> future,
    List<Completer<ProbeCandidateResult>> completers,
    Future<void> Function() flush
  ) run(List<ProbeCandidateSpec> cs) {
    final completers = List.generate(
      cs.length,
      (_) => Completer<ProbeCandidateResult>(),
    );
    final byAddr = {for (var i = 0; i < cs.length; i++) cs[i].address: i};

    Future<ProbeCandidateResult> probe(ProbeCandidateSpec c, CancelToken _) =>
        completers[byAddr[c.address]!].future;

    final future = service.probeBestReachableForTest(
      candidates: cs,
      cancelToken: CancelToken(),
      probe: probe,
    );

    return (future, completers, () => pumpEventQueue());
  }

  /// 断言 helper 尚未返回（仍有更高优先级候选未决）。
  /// future 由 completer 驱动，此处不可能意外完成；若有则直接失败暴露竞态。
  Future<void> expectPending(
    Future<
        ({
          ProbeCandidateResult? best,
          int? bestIndex,
          List<ProbeCandidateResult> decided,
        })> future,
  ) async {
    var done = false;
    future.then((_) => done = true);
    await pumpEventQueue();
    expect(done, isFalse, reason: '此时不应已返回（仍有候选未决）');
  }

  test('最高优先级可达 → 立即返回，忽略未完成的低优先级', () async {
    final cs = specs(4);
    final (f, completers, flush) = run(cs);

    completers[0].complete(reachable(0));
    final r = await f;
    expect(r.best, isNotNull);
    expect(r.best!.address, cs[0].address, reason: '应选最高优先级候选');
    expect(r.bestIndex, 0);
    expect(r.decided.length, 1, reason: '早停：其余候选尚未出结果');

    // 冲刷并补全其余候选：孤儿 future 结果应被吞掉，无未处理 async error
    completers[1].complete(unreachable(1));
    completers[2].complete(reachable(2));
    completers[3].complete(unreachable(3));
    await flush();
  });

  test('低优先级先通、高优先级未决 → 继续等；高优先级可达 → 选高优先级', () async {
    final cs = specs(4);
    final (f, completers, _) = run(cs);

    completers[3].complete(reachable(3));
    await expectPending(f);

    completers[0].complete(reachable(0));
    final r = await f;
    expect(r.best!.address, cs[0].address, reason: '优先级高于速度');
    expect(r.bestIndex, 0);
  });

  test('高优先级已失败、低优先级可达 → 立即返回低优先级', () async {
    final cs = specs(4);
    final (f, completers, _) = run(cs);

    completers[0].complete(unreachable(0));
    completers[1].complete(reachable(1));
    final r = await f;
    expect(r.best!.address, cs[1].address);
    expect(r.bestIndex, 1);
    expect(r.decided.length, 2, reason: '早停：2、3 未决');
  });

  test('低优先级先通、高优先级最终不可达 → 落在低优先级', () async {
    final cs = specs(4);
    final (f, completers, _) = run(cs);

    completers[2].complete(reachable(2));
    await expectPending(f);

    // c1 比 c2 优先级更高且仍未决定 → 即便 c0 已确认不可达，仍需等 c1
    completers[0].complete(unreachable(0));
    await expectPending(f);

    completers[1].complete(unreachable(1));
    final r = await f;
    expect(r.best!.address, cs[2].address);
    expect(r.bestIndex, 2);
  });

  test('次高优先级升级覆盖已确认的更低位（c1 未决期间不选 c2）', () async {
    final cs = specs(4);
    final (f, completers, _) = run(cs);

    completers[0].complete(unreachable(0));
    completers[2].complete(reachable(2));
    await expectPending(f);

    completers[1].complete(reachable(1));
    final r = await f;
    expect(r.best!.address, cs[1].address, reason: 'c2 虽通，但更高优先 c1 未决');
    expect(r.bestIndex, 1);
  });

  test('完成顺序不破坏优先级（c1 先通、c0 后通 → 选 c0）', () async {
    final cs = specs(4);
    final (f, completers, _) = run(cs);

    completers[1].complete(reachable(1));
    await expectPending(f);

    completers[0].complete(reachable(0));
    final r = await f;
    expect(r.best!.address, cs[0].address);
    expect(r.bestIndex, 0);
  });

  test('全部不可达 → best 为 null、decided 含全部候选（摘要路径保留）', () async {
    final cs = specs(4);
    final (f, completers, _) = run(cs);

    for (var i = 0; i < 4; i++) {
      completers[i].complete(unreachable(i));
    }
    final r = await f;
    expect(r.best, isNull);
    expect(r.bestIndex, isNull);
    expect(r.decided.length, 4, reason: '全部失败须返回完整结果供摘要');
    expect(r.decided.every((x) => !x.isReachable), isTrue);
  });

  test('空候选 → (null, null, [])，不抛 StateError', () async {
    final (f, _, _) = run(const []);
    final r = await f;
    expect(r.best, isNull);
    expect(r.bestIndex, isNull);
    expect(r.decided, isEmpty);
  });

  test('单候选：可达立即返回 / 不可达 best 为 null', () async {
    final cs = specs(1);
    final (f, completers, _) = run(cs);

    completers[0].complete(reachable(0));
    var r = await f;
    expect(r.best!.address, cs[0].address);
    expect(r.bestIndex, 0);

    final cs2 = specs(1);
    final (f2, completers2, _) = run(cs2);
    completers2[0].complete(unreachable(0));
    r = await f2;
    expect(r.best, isNull);
    expect(r.bestIndex, isNull);
  });

  test('取消优先：token 取消后即使候选已通也抛「探测已取消」', () async {
    final cs = specs(4);
    final completers = List.generate(
      4,
      (_) => Completer<ProbeCandidateResult>(),
    );
    final byAddr = {for (var i = 0; i < cs.length; i++) cs[i].address: i};
    Future<ProbeCandidateResult> probe(ProbeCandidateSpec c, CancelToken _) =>
        completers[byAddr[c.address]!].future;

    final token = CancelToken();
    final f = service.probeBestReachableForTest(
      candidates: cs,
      cancelToken: token,
      probe: probe,
    );

    token.cancel();
    completers[0].complete(reachable(0));
    await expectLater(
      f,
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('探测已取消'),
        ),
      ),
    );
  });

  test('候选 future 以 cancel 类型 DioException 失败 → 向上传播', () async {
    final cs = specs(4);
    final completers = List.generate(
      4,
      (_) => Completer<ProbeCandidateResult>(),
    );
    final byAddr = {for (var i = 0; i < cs.length; i++) cs[i].address: i};
    Future<ProbeCandidateResult> probe(ProbeCandidateSpec c, CancelToken _) =>
        completers[byAddr[c.address]!].future;

    final f = service.probeBestReachableForTest(
      candidates: cs,
      cancelToken: CancelToken(),
      probe: probe,
    );

    completers[0].completeError(
      DioException(
        requestOptions: RequestOptions(path: cs[0].address),
        type: DioExceptionType.cancel,
      ),
    );
    await expectLater(f, throwsA(isA<DioException>()));
  });
}
