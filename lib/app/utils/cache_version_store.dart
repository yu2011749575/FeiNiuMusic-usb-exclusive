class CacheVersionStore {
  CacheVersionStore._();

  static final CacheVersionStore instance = CacheVersionStore._();

  final Map<String, int> _versions = <String, int>{};

  int getVersion(String scope) {
    return _versions[scope] ?? 0;
  }

  int bump(String scope) {
    final next = getVersion(scope) + 1;
    _versions[scope] = next;
    return next;
  }

  void setVersion(String scope, int version) {
    _versions[scope] = version;
  }
}
