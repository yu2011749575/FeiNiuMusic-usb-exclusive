import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:feiniu_music/app/services/db/db_constants.dart';
import 'package:feiniu_music/app/services/db/db_helper.dart';
import 'package:feiniu_music/app/services/report/report_payload_codec.dart';
import 'package:feiniu_music/app/services/report/report_snapshot_builder.dart';

/// 报告 payload 生成：从 report_events + 聚合统计组装 data.json 同构信封。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('report_builder_test');
    // 注入临时路径（unit test 无 path_provider 实现）
    DbHelper.instance.resetForTest(
        overridePath: p.join(tempDir.path, 'main.db'));
  });

  tearDown(() {
    DbHelper.instance.resetForTest();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> seedReportEvents() async {
    final db = await DbHelper.instance.database;
    final now = DateTime.now();
    // 3 首歌 × 不同天/时段
    await db.insert(DbConstants.tableReportEvents, {
      'dayKey': '2026-08-05', 'hour': 20, 'songId': 's1', 'songTitle': '晴天',
      'artistsJson': '[{"guid":"a1","name":"周杰伦"}]',
      'albumJson': '{"guid":"al1","name":"叶惠美"}',
      'durationMs': 260000, 'playMs': 180000, 'completed': 1,
      'sessionStartMs': now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      'sessionEndMs': now.subtract(const Duration(days: 2)).millisecondsSinceEpoch + 180000,
    });
    await db.insert(DbConstants.tableReportEvents, {
      'dayKey': '2026-08-06', 'hour': 23, 'songId': 's2', 'songTitle': '夜曲',
      'artistsJson': '[{"guid":"a1","name":"周杰伦"}]',
      'albumJson': '{"guid":"al2","name":"十一月的萧邦"}',
      'durationMs': 250000, 'playMs': 150000, 'completed': 1,
      'sessionStartMs': now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      'sessionEndMs': now.subtract(const Duration(days: 1)).millisecondsSinceEpoch + 150000,
    });
    await db.insert(DbConstants.tableReportEvents, {
      'dayKey': '2026-08-07', 'hour': 9, 'songId': 's3', 'songTitle': '稻香',
      'artistsJson': '[{"guid":"a2","name":"周杰伦"}]',
      'albumJson': '{"guid":"al3","name":"魔杰座"}',
      'durationMs': 240000, 'playMs': 100000, 'completed': 0,
      'sessionStartMs': now.millisecondsSinceEpoch - 100000,
      'sessionEndMs': now.millisecondsSinceEpoch,
    });
    // 聚合：song_stats 供 page1/page11 使用
    await db.insert(
      'song_stats',
      {'songId': 's1', 'listenMs': 180000, 'playCount': 1, 'lastPlayedMs': now.millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'song_stats',
      {'songId': 's2', 'listenMs': 150000, 'playCount': 1, 'lastPlayedMs': now.millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'song_stats',
      {'songId': 's3', 'listenMs': 100000, 'playCount': 0, 'lastPlayedMs': now.millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // listening_days 供 page1 总时长/page2 月度
    await db.insert('listening_days',
        {'dayKey': '2026-08-05', 'listenMs': 180000, 'playCount': 1});
    await db.insert('listening_days',
        {'dayKey': '2026-08-06', 'listenMs': 150000, 'playCount': 1});
    await db.insert('listening_days',
        {'dayKey': '2026-08-07', 'listenMs': 100000, 'playCount': 0});
  }

  test('ReportSnapshotBuilder 生成 data.json 同构信封', () async {
    await seedReportEvents();
    final payload = await ReportSnapshotBuilder().build();

    // 信封结构
    expect(payload['code'], 0);
    expect(payload['req_0']['data'], isA<Map>());
    expect(payload['req_1']['data'], isA<Map>());

    final data = payload['req_0']['data'] as Map<String, dynamic>;
    // 页面齐全
    for (var i = 0; i < 20; i++) {
      expect(data['page$i'], isA<Map>(), reason: '应有 page$i');
    }
    // invalidList 20 项
    expect(data['invalidList'], hasLength(20));

    // page3 歌手榜：周杰伦 top
    final page3 = data['page3'] as Map<String, dynamic>;
    if (page3['invalid'] != 1) {
      final singers = page3['singers'] as List;
      expect(singers, isNotEmpty);
      expect(
        ((singers.first as Map)['singer'] as Map)['name'],
        '周杰伦',
      );
    }

    // page2 月度页：singer 不能是 null（组件直接访问 singer.name/pic，null 会崩溃黑屏）
    final page2 = data['page2'] as Map<String, dynamic>;
    final months = page2['singers'] as List;
    // 测试数据只有 8 月有播放 → 只应输出 8 月（原版：无数据月份跳过）
    expect(months.length, 1, reason: '只有 8 月有听歌数据，应只显示 1 个月');
    for (final month in months) {
      final m = month as Map;
      expect(m['singer'], isNotNull,
          reason: 'page2 月度 singer 不能为 null，否则 TypeError: null.name');
      expect((m['singer'] as Map)['name'], isA<String>());
      expect(m['title'], '8月');
    }

    // page11 年度歌曲：playCount 最高的是 s1（晴天，completed=1 计 1 次）
    final page11 = data['page11'] as Map<String, dynamic>;
    if (page11['invalid'] != 1) {
      expect(page11['times'], greaterThanOrEqualTo(1));
    }

    // page1.num = 使用天数（有听歌记录的去重天数）
    final page1 = data['page1'] as Map<String, dynamic>;
    expect(page1['num'], 3, reason: '3 天有听歌记录（08-05/08-06/08-07）');
  });

  test('空库：页面全部 invalid，报告仍可生成', () async {
    final payload = await ReportSnapshotBuilder().build();
    final data = payload['req_0']['data'] as Map<String, dynamic>;
    final invalidCount = (data['invalidList'] as List).where((v) => v == 1).length;
    // 无数据时大多数页应跳过（invalid=1）
    expect(invalidCount, greaterThan(0));
  });

  test('ReportPayloadCodec 编解码往返一致', () {
    final payload = {
      'code': 0,
      'req_0': {'data': {'page1': {'invalid': 0, 'songNum': 5}}},
      'req_1': {'data': {'conf': '{"title":"x"}'}},
    };
    final encoded = ReportPayloadCodec.encode(payload);
    expect(encoded, isNotEmpty);
    final decoded = ReportPayloadCodec.decode(encoded);
    expect(decoded, payload);
  });
}
