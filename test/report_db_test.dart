import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:feiniu_music/app/services/db/db_constants.dart';
import 'package:feiniu_music/app/services/db/db_helper.dart';
import 'package:feiniu_music/app/services/listening_recorder_service.dart';
import 'package:feiniu_music/app/state/player_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 主库 report_events（v16 起并入 feiniu_music.db）：建表、幂等重开、
/// record + prune。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('report_db_test');
  });

  tearDown(() {
    DbHelper.instance.resetForTest();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('全新 onCreate：report_events 表可建、可写、可查', () async {
    final dbPath = p.join(tempDir.path, 'feiniu_music.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    // 表存在且字段正确
    final cols = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableReportEvents})',
    );
    final names = cols.map((r) => r['name']).toSet();
    expect(names, contains('dayKey'));
    expect(names, contains('hour'));
    expect(names, contains('songId'));
    expect(names, contains('playMs'));
    expect(names, contains('completed'));
    expect(names, contains('sessionEndMs'));

    // 插入一条事件
    await db.insert(DbConstants.tableReportEvents, {
      'dayKey': '2026-08-07',
      'hour': 20,
      'songId': 'song-1',
      'songTitle': '测试歌曲',
      'artistsJson': '[{"guid":"a1","name":"测试歌手"}]',
      'albumJson': '{"guid":"al1","name":"测试专辑"}',
      'coverId': 'cover-1',
      'durationMs': 240000,
      'playMs': 120000,
      'completed': 1,
      'sessionStartMs': 1754000000000,
      'sessionEndMs': 1754000120000,
    });

    final rows = await db.query(DbConstants.tableReportEvents);
    expect(rows.length, 1);
    expect(rows.single['songTitle'], '测试歌曲');
    expect(rows.single['completed'], 1);
  });

  test('幂等重开：重复 resetForTest + database 不抛错', () async {
    final dbPath = p.join(tempDir.path, 'feiniu_music.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db1 = await DbHelper.instance.database;
    await db1.insert(DbConstants.tableReportEvents, {
      'dayKey': '2026-08-07',
      'hour': 9,
      'songId': 'song-2',
      'songTitle': '重复打开',
      'playMs': 1000,
      'completed': 0,
      'sessionStartMs': 1,
      'sessionEndMs': 1001,
    });

    // 重置后重开同一文件
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db2 = await DbHelper.instance.database;
    final rows = await db2.query(DbConstants.tableReportEvents);
    expect(rows.length, 1, reason: '重开不应丢失数据');
  });

  test('ListeningRecorderService：播放累计 → 落库 report_events', () async {
    final dbPath = p.join(tempDir.path, 'feiniu_music.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;
    final recorder = ListeningRecorderService.instance;

    final song = SongEntity(
      id: 'song-3',
      title: '起风了',
      artist: '[{"guid":"a3","name":"买辣椒也用券"}]',
      album: '{"guid":"al3","name":"起风了"}',
      durationMs: 250000,
    );

    // 模拟连续播放：两次快照，累计 ~2s
    recorder.onSnapshot(_snap(song, isPlaying: true, posMs: 0));
    await _advance(700);
    recorder.onSnapshot(_snap(song, isPlaying: true, posMs: 700));
    await _advance(700);
    recorder.onSnapshot(_snap(song, isPlaying: true, posMs: 1400));
    await _advance(700);
    recorder.onSnapshot(_snap(song, isPlaying: true, posMs: 2100));

    // 切歌/暂停 → finalize 落库
    recorder.onSnapshot(_snap(null, isPlaying: false, posMs: 2100));
    await _settle();

    final rows = await db.query(DbConstants.tableReportEvents);
    expect(rows.length, 1, reason: '一次连续播放应落一条 session');
    expect(rows.single['songId'], 'song-3');
    expect(rows.single['playMs'], greaterThanOrEqualTo(2000));
    expect(rows.single['songTitle'], '起风了');
    expect(rows.single['completed'], 0);
  });

  test('ListeningRecorderService：markCompleted 标记完整播完', () async {
    final dbPath = p.join(tempDir.path, 'feiniu_music.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;
    final recorder = ListeningRecorderService.instance;

    final song = SongEntity(id: 'song-4', title: '完整播完', artist: '[]');
    recorder.onSnapshot(_snap(song, isPlaying: true, posMs: 0));
    await _advance(500);
    recorder.onSnapshot(_snap(song, isPlaying: true, posMs: 500));
    await _advance(500);
    recorder.markCompleted();
    await _settle();

    final rows = await db.query(DbConstants.tableReportEvents);
    expect(rows.length, 1);
    expect(rows.single['completed'], 1, reason: '完整播完应标记 completed=1');
  });

  test('90 天滚动清理：过期事件被删除', () async {
    final dbPath = p.join(tempDir.path, 'feiniu_music.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final now = DateTime.now();
    final oldMs = now.subtract(const Duration(days: 100)).millisecondsSinceEpoch;
    final freshMs = now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;

    await db.insert(DbConstants.tableReportEvents, {
      'dayKey': 'old', 'hour': 1, 'songId': 'old-1', 'songTitle': '旧',
      'playMs': 100, 'completed': 0,
      'sessionStartMs': oldMs - 100, 'sessionEndMs': oldMs,
    });
    await db.insert(DbConstants.tableReportEvents, {
      'dayKey': 'new', 'hour': 1, 'songId': 'new-1', 'songTitle': '新',
      'playMs': 100, 'completed': 0,
      'sessionStartMs': freshMs - 100, 'sessionEndMs': freshMs,
    });

    final cutoff = now.subtract(ListeningRecorderService.retentionWindow)
        .millisecondsSinceEpoch;
    await db.delete(
      DbConstants.tableReportEvents,
      where: 'sessionEndMs < ?',
      whereArgs: [cutoff],
    );

    final rows = await db.query(DbConstants.tableReportEvents);
    expect(rows.length, 1, reason: '过期事件应被清理，新事件保留');
    expect(rows.single['songId'], 'new-1');
  });
}

PlaybackSnapshot _snap(SongEntity? song,
    {required bool isPlaying, required int posMs}) {
  return PlaybackSnapshot(
    song: song,
    queue: song == null ? const [] : [song],
    index: song == null ? -1 : 0,
    isPlaying: isPlaying,
    position: Duration(milliseconds: posMs),
    duration: song?.durationMs == null ? null : Duration(milliseconds: song!.durationMs!),
    bufferedPosition: Duration.zero,
  );
}

Future<void> _advance(int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}
