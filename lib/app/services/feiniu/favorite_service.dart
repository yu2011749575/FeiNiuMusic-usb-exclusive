import 'api_client.dart';

/// 飞牛收藏服务
class FeiNiuFavoriteService {
  FeiNiuFavoriteService._();

  static final FeiNiuFavoriteService instance = FeiNiuFavoriteService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 获取收藏歌曲 ID 集合
  Future<Set<String>> getFavoriteIds() async {
    final pageData = await _api.getFavoriteList();
    return pageData.list.map((t) => t.guid).toSet();
  }

  /// 获取收藏歌曲列表
  Future<List<dynamic>> getFavoriteList() async {
    final pageData = await _api.getFavoriteList();
    return pageData.list;
  }

  /// 收藏歌曲
  Future<void> favorite(String trackGuid) async {
    await _api.favoriteTrack(trackGuid);
  }

  /// 批量收藏（接口无批量，逐首调用）。返回失败数量。
  ///
  /// 收藏页多选等场景使用；单首失败不中断其余。
  Future<int> favoriteAll(List<String> trackGuids) async {
    var failed = 0;
    for (final id in trackGuids) {
      try {
        await _api.favoriteTrack(id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// 取消收藏
  Future<void> unfavorite(String trackGuid) async {
    await _api.unfavoriteTrack(trackGuid);
  }

  /// 批量取消收藏（接口无批量，逐首调用）。返回失败数量。
  ///
  /// 收藏页多选等场景使用；单首失败不中断其余。
  Future<int> unfavoriteAll(List<String> trackGuids) async {
    var failed = 0;
    for (final id in trackGuids) {
      try {
        await _api.unfavoriteTrack(id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// 检查是否已收藏
  Future<bool> isFavorite(String trackGuid) async {
    final ids = await getFavoriteIds();
    return ids.contains(trackGuid);
  }
}
