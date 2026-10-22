import 'api_client.dart';
import 'api_models.dart';

/// 飞牛专辑服务
class FeiNiuAlbumService {
  FeiNiuAlbumService._();

  static final FeiNiuAlbumService instance = FeiNiuAlbumService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 获取专辑列表
  Future<List<FeiNiuAlbum>> getAlbumList({
    int page = 1,
    int size = 50,
    String? sort,
  }) async {
    final pageData = await _api.getAlbumList(
      page: page,
      size: size,
      sort: sort,
    );
    return pageData.list;
  }

  /// 获取专辑详情（曲目列表）
  Future<List<FeiNiuTrack>> getAlbumTracks(
    String albumGuid, {
    int page = 1,
    int size = 120,
  }) async {
    final pageData = await _api.getAlbumTracks(
      albumGUID: albumGuid,
      page: page,
      size: size,
    );
    return pageData.list;
  }
}
