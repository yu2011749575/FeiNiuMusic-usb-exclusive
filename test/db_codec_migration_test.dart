import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:feiniu_music/app/services/db/db_constants.dart';
import 'package:feiniu_music/app/services/db/db_helper.dart';

/// 校验 `songs` 表 schema 与 `SongEntity.toMap()` 的列集合保持一致——
/// 防止再次出现「toMap 写某列但 schema 没有该列 → INSERT OR REPLACE 抛
/// no such column → 整个事务回滚 → 元数据/统计丢失」。
///
/// 历史同类故障：v12 缺 updatedAt、v14 漏加 isCue（见 db_helper 注释）。
/// 这次引入 codec 列必须同时满足：
/// 1. 旧库（v14 及以下）升级到 v15 后能查/写 codec 列（迁移幂等）；
/// 2. 全新安装（onCreate）直接含 codec 列；
/// 3. 写入含 codec 的 SongEntity 事务不抛错（数据可读回）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('db_codec_test');
  });

  tearDown(() {
    // 关闭并重置 DbHelper 缓存连接，避免跨测试污染。
    DbHelper.instance.resetForTest();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> createLegacyV14Db(String path) async {
    // 用 v14 之前的历史 schema 建旧库（不含 codec 列）。
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 14,
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE ${DbConstants.tableSongs} (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT,
  uri TEXT,
  isLocal INTEGER NOT NULL DEFAULT 0,
  headersJson TEXT,
  durationMs INTEGER,
  bitrate INTEGER,
  sampleRate INTEGER,
  fileSize INTEGER,
  format TEXT,
  isFavorite INTEGER NOT NULL DEFAULT 0,
  coverId TEXT,
  audioSpec TEXT,
  trackNumber INTEGER,
  discNumber INTEGER,
  updatedAt INTEGER,
  isCue INTEGER NOT NULL DEFAULT 0,
  cueOffsetMs INTEGER
)
''');
        },
      ),
    );
    await legacy.close();
  }

  test('v14 旧库升级到 v15：codec 列被添加，写入不抛错', () async {
    final dbPath = p.join(tempDir.path, 'legacy.db');
    await createLegacyV14Db(dbPath);

    // 注入路径并走真实 _openDb 迁移（v14→v15 应 ALTER 加 codec 列）。
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final cols = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableSongs})',
    );
    final names = cols.map((r) => r['name']).toSet();
    expect(names, contains('codec'), reason: 'v15 迁移后应有 codec 列');

    // 复现 SongDao.upsertSongs / StatsService 的事务语义：
    // batch INSERT OR REPLACE 写含 codec 的 toMap()。
    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.insert(
        DbConstants.tableSongs,
        {
          'id': 's1',
          'title': '我等你',
          'artist': '[{"name":"刘若英"}]',
          'format': 'm4a',
          'codec': 'eac3',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
    final row = await db.query(
      DbConstants.tableSongs,
      where: 'id = ?',
      whereArgs: ['s1'],
    );
    expect(row.single['codec'], 'eac3');
  });

  test('全新安装（onCreate）的 songs 表直接含 codec 列', () async {
    final dbPath = p.join(tempDir.path, 'fresh.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final cols = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableSongs})',
    );
    final names = cols.map((r) => r['name']).toSet();
    expect(names, contains('codec'));
  });

  test('迁移幂等：v15 库再开不重复加列、不抛 duplicate column', () async {
    final dbPath = p.join(tempDir.path, 'current.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    await DbHelper.instance.database;
    // 关闭重开（同版本）：onUpgrade 不触发，schema 不变，不抛错。
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;
    final cols = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableSongs})',
    );
    final names = cols.map((r) => r['name']).toSet();
    expect(names, contains('codec'));
  });

  // ---- isAudioFileDeleted 列（v17）----
  Future<void> createLegacyV16Db(String path) async {
    // v16 历史 schema：含 codec/isCue/cueOffsetMs，但缺 isAudioFileDeleted。
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 16,
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE ${DbConstants.tableSongs} (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT,
  uri TEXT,
  isLocal INTEGER NOT NULL DEFAULT 0,
  headersJson TEXT,
  durationMs INTEGER,
  bitrate INTEGER,
  sampleRate INTEGER,
  fileSize INTEGER,
  format TEXT,
  codec TEXT,
  isFavorite INTEGER NOT NULL DEFAULT 0,
  coverId TEXT,
  audioSpec TEXT,
  trackNumber INTEGER,
  discNumber INTEGER,
  updatedAt INTEGER,
  isCue INTEGER NOT NULL DEFAULT 0,
  cueOffsetMs INTEGER
)
''');
        },
      ),
    );
    await legacy.close();
  }

  test('v16 旧库升级到 v17：isAudioFileDeleted 列被添加，写入不抛错', () async {
    final dbPath = p.join(tempDir.path, 'legacy-v16.db');
    await createLegacyV16Db(dbPath);

    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final cols = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableSongs})',
    );
    final names = cols.map((r) => r['name']).toSet();
    expect(names, contains('isAudioFileDeleted'),
        reason: 'v17 迁移后应有 isAudioFileDeleted 列');

    // 复现 SongEntity.toMap() 的写入语义：INSERT OR REPLACE 带 isAudioFileDeleted。
    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.insert(
        DbConstants.tableSongs,
        {
          'id': 's-broken',
          'title': '病态',
          'artist': '[{"name":"..."}]',
          'codec': 'flac',
          'isAudioFileDeleted': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
    final row = await db.query(
      DbConstants.tableSongs,
      where: 'id = ?',
      whereArgs: ['s-broken'],
    );
    expect(row.single['isAudioFileDeleted'], 1);
  });

  test('全新安装（onCreate）的 songs 表直接含 isAudioFileDeleted 列', () async {
    final dbPath = p.join(tempDir.path, 'fresh-v17.db');
    DbHelper.instance.resetForTest(overridePath: dbPath);
    final db = await DbHelper.instance.database;

    final cols = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableSongs})',
    );
    final names = cols.map((r) => r['name']).toSet();
    expect(names, contains('isAudioFileDeleted'));
  });
}
