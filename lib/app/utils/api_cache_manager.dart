import 'dart:async';

import '../services/db/dao/song_dao.dart';
import 'page_cache_store.dart';

/// API 响应缓存管理器 —— 统一数据缓存的入口。
///
/// 两层缓存：
/// - Tier 1（热）：[PageCacheStore] 内存 LRU（256 条）
/// - Tier 2（温）：[SongDao.api_cache] SQLite 表带 TTL
///
/// 核心能力：
/// - [cacheThenNetwork]：Stale-While-Revalidate 模式
/// - [get]/[set]：常规读写（内存优先）
/// - [refresh]：强制刷新并更新缓存
class ApiCacheManager {
  ApiCacheManager._();

  static final ApiCacheManager instance = ApiCacheManager._();

  final PageCacheStore _memory = PageCacheStore.instance;
  final SongDao _dao = SongDao.instance;

  /// 存 JSON 到两层缓存。
  ///
  /// [ttlMs] 默认 null = 永久缓存（与读路径 ignoreTtl 一致：数据永久保留，
  /// 除非用户清空缓存或页面下拉刷新覆盖）。传非空值才按时间淘汰。
  Future<void> set({
    required String scope,
    required String key,
    required String jsonData,
    int? ttlMs,
  }) async {
    _memory.set(scope, key, jsonData, ttlMs: ttlMs);
    await _dao.cacheApiResponse(_compositeKey(scope, key), jsonData, ttlMs: ttlMs);
  }

  /// 从 SQLite 读取持久化缓存（忽略 TTL —— 离线也可用）。
  /// 返回 null 仅当数据根本不存在。
  Future<String?> getPersisted(String scope, String key) async {
    try {
      return await _dao.getCachedApiResponse(_compositeKey(scope, key), ignoreTtl: true);
    } catch (_) {
      return null;
    }
  }

  /// 更新内存缓存（页面切换等场景用，无需写 SQLite）
  void setMemory(String scope, String key, String jsonData) {
    _memory.set(scope, key, jsonData);
  }

  String _compositeKey(String scope, String key) => '$scope::$key';

  /// 无缓存 → 同步拉网络，完成后写缓存
  /// 有缓存 → 立即返回缓存数据，同时在后台发起刷新
  ///
  /// 返回：
  /// - [Future] 完成时如果为 null → 表示没命中缓存，数据已经给了 fetchCallback
  /// - [Future] 完成时有数据 → 这是缓存数据，同时在后台启动了刷新
  Future<T?> cacheThenNetwork<T>({
    required String scope,
    required String key,
    required Future<T> Function() fetch,
    required T Function(String json) fromJson,
    required String Function(T data) toJson,
    required void Function(T? data) fetchCallback,
    int? ttlMs,
  }) async {
    // 1. 检查 SQLite 持久化缓存
    try {
      final cachedJson = await getPersisted(scope, key);
      if (cachedJson != null) {
        try {
          final cachedData = fromJson(cachedJson);
          _memory.set(scope, key, cachedJson);
          // 后台刷新（结果通过 fetchCallback 返回）
          unawaited(_refreshInBackground(
            scope, key, fetch, toJson, ttlMs, fetchCallback,
          ));
          return cachedData;
        } catch (_) {
          // 缓存数据格式异常（如 schema 变更），抛弃缓存
        }
      }
    } catch (_) {
      // DB 读取失败
    }

    // 2. 无缓存或缓存失效 → 同步等网络
    final freshData = await fetch();
    final json = toJson(freshData);
    // SQLite 可能因 schema 问题不可用，写入失败不阻塞数据展示
    try {
      await set(scope: scope, key: key, jsonData: json, ttlMs: ttlMs);
    } catch (_) {
      // 缓存写入失败（如 DB schema 问题），数据仍可正常展示
    }
    fetchCallback(freshData);
    return null;
  }

  Future<void> _refreshInBackground<T>(
    String scope,
    String key,
    Future<T> Function() fetch,
    String Function(T) toJson,
    int? ttlMs,
    void Function(T? data) fetchCallback,
  ) async {
    try {
      final fresh = await fetch();
      final json = toJson(fresh);
      _memory.set(scope, key, json, ttlMs: ttlMs);
      await _dao.cacheApiResponse(
        _compositeKey(scope, key), json, ttlMs: ttlMs,
      );
      fetchCallback(fresh);
    } catch (_) {
      // 后台刷新失败（断网等），通知页面刷新完成以关掉右上角转圈
      fetchCallback(null);
    }
  }

  /// 强制刷新 —— 忽略缓存，拉取后更新。
  Future<T> refresh<T>({
    required String scope,
    required String key,
    required Future<T> Function() fetch,
    required String Function(T data) toJson,
    int? ttlMs,
  }) async {
    final freshData = await fetch();
    final json = toJson(freshData);
    _memory.set(scope, key, json, ttlMs: ttlMs);
    await _dao.cacheApiResponse(_compositeKey(scope, key), json, ttlMs: ttlMs);
    return freshData;
  }
}
