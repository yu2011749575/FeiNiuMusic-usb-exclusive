import 'api_client.dart';
import 'api_models.dart';

/// 飞牛歌手服务
class FeiNiuArtistService {
  FeiNiuArtistService._();

  static final FeiNiuArtistService instance = FeiNiuArtistService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 获取歌手列表
  Future<List<FeiNiuArtist>> getArtistList({
    int page = 1,
    int size = 200,
  }) async {
    final pageData = await _api.getArtistList(page: page, size: size);
    return pageData.list;
  }

  /// 获取歌手歌曲
  Future<List<FeiNiuTrack>> getArtistTracks(
    String artistGuid, {
    int page = 1,
    int size = 120,
    String? sort,
  }) async {
    final pageData = await _api.getArtistTracks(
      artistGUID: artistGuid,
      page: page,
      size: size,
      sort: sort,
    );
    return pageData.list;
  }
}
