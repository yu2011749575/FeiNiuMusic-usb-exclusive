import 'dart:collection';

class _CacheEntry {
  final Object? value;
  final int cachedAtMs;
  final int? ttlMs;

  bool get isExpired {
    if (ttlMs == null) return false;
    return DateTime.now().millisecondsSinceEpoch - cachedAtMs > ttlMs!;
  }

  _CacheEntry(this.value, this.cachedAtMs, this.ttlMs);
}

class PageCacheStore {
  PageCacheStore._();

  static final PageCacheStore instance = PageCacheStore._();

  static const int _maxEntries = 256;

  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();

  String _fullKey(String scope, String key) => '$scope::$key';

  T? get<T>(String scope, String key) {
    final fullKey = _fullKey(scope, key);
    final entry = _entries[fullKey];
    if (entry == null) return null;
    if (entry.isExpired) {
      _entries.remove(fullKey);
      return null;
    }
    // LRU promotion
    _entries.remove(fullKey);
    _entries[fullKey] = entry;
    return entry.value as T?;
  }

  void set<T>(String scope, String key, T value, {int? ttlMs}) {
    final fullKey = _fullKey(scope, key);
    _entries.remove(fullKey);
    _entries[fullKey] = _CacheEntry(value, DateTime.now().millisecondsSinceEpoch, ttlMs);
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(String scope, String key) {
    _entries.remove(_fullKey(scope, key));
  }

  void clearScope(String scope) {
    final prefix = '$scope::';
    final keys = _entries.keys.where((key) => key.startsWith(prefix)).toList();
    for (final key in keys) {
      _entries.remove(key);
    }
  }

  void clearAll() {
    _entries.clear();
  }
}
