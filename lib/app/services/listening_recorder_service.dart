import 'package:flutter/foundation.dart';

import '../state/player_state.dart';
import '../state/song_state.dart';
import 'db/db_constants.dart';
import 'db/db_helper.dart';

/// 听歌报告埋点：把每次「单曲播放 session」落成一条 [DbConstants.tableReportEvents]
/// 记录，存于主库 `feiniu_music.db`（与聚合统计同库，便于统一备份）。
///
/// 与 [StatsService] 的分工：
/// - StatsService 维护**聚合**（song_stats/listening_days…，在主库），永久保留、容量有界；
/// - 本服务维护**原始事件**（report_events，同在主库），用于听歌报告的时段/连续/深夜/
///   四季等聚合表覆盖不了的洞察，按滚动窗口保留（见 [retentionWindow]，默认 90 天）。
///
/// 整机共享：不区分账号/FNID（与现有 song_stats/listening_days 语义一致）。
///
/// 调用方在每次 [PlaybackSnapshot] 时驱动 [onSnapshot]；当同一首歌连续播放时
/// 累计 [playMs]，只有完整播完（[markCompleted]）或离开该歌曲时才落库。90 天
/// 滚动清理在写入后惰性执行，避免每次写都全表扫描。
class ListeningRecorderService {
  ListeningRecorderService._internal();

  static final ListeningRecorderService instance =
      ListeningRecorderService._internal();

  /// 原始事件保留窗口：只保留最近 90 天的听歌 session。
  /// 注意：生成年度报告时会一次性把 report_events 快照进聚合的年度报告表
  /// （见 ReportSnapshotBuilder），因此滚动清理不会影响年度报告。
  static const Duration retentionWindow = Duration(days: 90);

  /// 连续播放累计窗口：距上次 tick 超过该时长视为一次新 session（与 StatsService
  /// 的 10s 上限一致，避免 App 休眠/切后台产生超大 delta）。
  static const Duration maxTickGap = Duration(seconds: 10);

  String? _currentSongId;
  SongEntity? _currentSong;
  int _sessionStartMs = 0;
  int _sessionEndMs = 0;
  int _playMs = 0;
  DateTime? _lastTickAt;

  bool _flushRunning = false;

  /// 收到播放快照，累计当前歌曲的播放时长。
  ///
  /// [isPlaying] 为 false 或切歌时结束当前 session；切歌时旧 session 先落库。
  /// 与 StatsService.onSnapshot 相同的语义，但只关注「事件」本身。
  void onSnapshot(PlaybackSnapshot snapshot) {
    final song = snapshot.song;
    final now = DateTime.now();

    // 歌曲变化：结束上一个 session（若有）并切换到新歌。
    if (_currentSongId != song?.id) {
      if (_currentSongId != null) {
        _finalizeCurrent();
      }
      _currentSongId = song?.id;
      _currentSong = song;
      _sessionStartMs = now.millisecondsSinceEpoch;
      _sessionEndMs = _sessionStartMs;
      _playMs = 0;
      _lastTickAt = now;
      if (song == null) return;
    }

    if (!snapshot.isPlaying || song == null) {
      _finalizeCurrent();
      _lastTickAt = null;
      return;
    }

    final last = _lastTickAt;
    _lastTickAt = now;
    if (last == null) return;
    var deltaMs = now.difference(last).inMilliseconds;
    if (deltaMs <= 0) return;
    if (deltaMs > maxTickGap.inMilliseconds) {
      deltaMs = maxTickGap.inMilliseconds;
    }
    _playMs += deltaMs;
    _sessionEndMs = now.millisecondsSinceEpoch;
  }

  /// 标记当前 session 为「完整播完」。
  void markCompleted() {
    if (_currentSongId == null) return;
    _finalizeCurrent(completed: true);
  }

  /// 把当前 session 落库（完整播完或离开歌曲/暂停时）。
  void flush() {
    _finalizeCurrent();
    _pruneIfNeeded();
  }

  /// 生命周期兜底：App 切后台/被杀时调用。
  void onLifecyclePause() {
    flush();
  }

  void _finalizeCurrent({bool completed = false}) {
    final songId = _currentSongId;
    final song = _currentSong;
    if (songId == null || song == null) return;
    final startMs = _sessionStartMs;
    final endMs = _sessionEndMs;
    final playMs = _playMs;
    _currentSongId = null;
    _currentSong = null;
    _playMs = 0;
    if (playMs <= 0) return;
    _enqueueInsert(
      dayKey: _dayKey(DateTime.fromMillisecondsSinceEpoch(endMs)),
      hour: DateTime.fromMillisecondsSinceEpoch(endMs).hour,
      songId: songId,
      songTitle: song.title,
      artistsJson: song.artist,
      albumJson: song.album,
      coverId: song.coverId,
      durationMs: song.durationMs,
      playMs: playMs,
      completed: completed,
      sessionStartMs: startMs,
      sessionEndMs: endMs,
    );
  }

  /// 逐条入队写库。写库与累计分离：累计在播放线程高频调用，写库用独立队列
  /// 合并，避免 DB 竞争阻塞播放。
  final List<Map<String, dynamic>> _pending = [];

  void _enqueueInsert({
    required String dayKey,
    required int hour,
    required String songId,
    required String songTitle,
    required String? artistsJson,
    required String? albumJson,
    required String? coverId,
    required int? durationMs,
    required int playMs,
    required bool completed,
    required int sessionStartMs,
    required int sessionEndMs,
  }) {
    _pending.add({
      'dayKey': dayKey,
      'hour': hour,
      'songId': songId,
      'songTitle': songTitle,
      'artistsJson': artistsJson,
      'albumJson': albumJson,
      'coverId': coverId,
      'durationMs': durationMs,
      'playMs': playMs,
      'completed': completed ? 1 : 0,
      'sessionStartMs': sessionStartMs,
      'sessionEndMs': sessionEndMs,
    });
    _drain();
  }

  Future<void> _drain() async {
    if (_flushRunning) return;
    final batch = List<Map<String, dynamic>>.from(_pending);
    if (batch.isEmpty) return;
    _pending.clear();
    _flushRunning = true;
    try {
      final db = await DbHelper.instance.database;
      await db.transaction((txn) async {
        for (final row in batch) {
          await txn.insert(DbConstants.tableReportEvents, row);
        }
      });
      // 写入后检查滚动清理（惰性，不必每次执行）
      _pruneIfNeeded();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ListeningRecorderService drain failed: $e');
      }
    } finally {
      _flushRunning = false;
    }
  }

  String _dayKey(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// 惰性滚动清理：距上次清理超过 retentionWindow 才执行一次，避免每次写都
  /// 全表扫描。删除后无条件保留「年度报告期间」的数据——但年度报告在生成时
  /// 已经快照进聚合，因此这里只需要按窗口删除即可。
  DateTime? _lastPruneAt;
  bool _pruneRunning = false;

  void _pruneIfNeeded() {
    if (_pruneRunning) return;
    final now = DateTime.now();
    final last = _lastPruneAt;
    if (last != null && now.difference(last) < retentionWindow) return;
    _lastPruneAt = now;
    _pruneRunning = true;
    _prune();
  }

  Future<void> _prune() async {
    try {
      final db = await DbHelper.instance.database;
      final cutoff =
          DateTime.now().subtract(retentionWindow).millisecondsSinceEpoch;
      await db.delete(
        DbConstants.tableReportEvents,
        where: 'sessionEndMs < ?',
        whereArgs: [cutoff],
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ListeningRecorderService prune failed: $e');
      }
    } finally {
      _pruneRunning = false;
    }
  }
}
