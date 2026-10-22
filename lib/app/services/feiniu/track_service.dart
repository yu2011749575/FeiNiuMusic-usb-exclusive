import 'dart:convert';

import '../../state/song_state.dart';
import 'api_client.dart';
import 'api_models.dart';

/// 飞牛曲目服务 — API 数据 ⇄ SongEntity 映射
class FeiNiuTrackService {
  FeiNiuTrackService._();

  static final FeiNiuTrackService instance = FeiNiuTrackService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 获取曲目列表
  Future<List<SongEntity>> getTrackList({
    int page = 1,
    int size = 50,
    String? sort,
    bool forceRefresh = false,
  }) async {
    final pageData = await _api.getTrackList(page: page, size: size, sort: sort);
    return pageData.list.map(_feiNiuTrackToEntity).toList();
  }

  /// 获取专辑内曲目
  Future<List<SongEntity>> getAlbumTracks(String albumGuid,
      {int page = 1, int size = 120}) async {
    final pageData =
        await _api.getAlbumTracks(albumGUID: albumGuid, page: page, size: size);
    return pageData.list.map(_feiNiuTrackToEntity).toList();
  }

  /// 获取歌手曲目
  Future<List<SongEntity>> getArtistTracks(String artistGuid,
      {int page = 1, int size = 120, String? sort}) async {
    final pageData = await _api.getArtistTracks(
        artistGUID: artistGuid, page: page, size: size, sort: sort);
    return pageData.list.map(_feiNiuTrackToEntity).toList();
  }

  /// 获取歌单内曲目
  Future<List<SongEntity>> getPlaylistTracks(String playlistGuid,
      {int page = 1, int size = 300}) async {
    final pageData = await _api.getPlaylistTracks(
        playlistGUID: playlistGuid, page: page, size: size);
    return pageData.list.map(_feiNiuTrackToEntity).toList();
  }

  /// 搜索
  Future<List<SongEntity>> searchTracks(String query) async {
    final pageData = await _api.searchTrack(query: query);
    return pageData.list.map((t) => _feiNiuTrackToEntity(t)).toList();
  }

  /// 快速从 FeiNiuTrack（或 Map）转为 SongEntity 的便捷方法
  SongEntity trackToSongEntity(dynamic track) {
    if (track is FeiNiuTrack) return _feiNiuTrackToEntity(track);
    if (track is Map<String, dynamic>) return _fromTrackMap(track);
    return _feiNiuTrackToEntity(FeiNiuTrack.fromJson(track as Map<String, dynamic>));
  }

  /// 将单个 FeiNiuTrack 映射为 SongEntity
  SongEntity _feiNiuTrackToEntity(FeiNiuTrack track) {
    final artistsJson = jsonEncode(
      track.artists.map((a) => {
        'guid': a.guid,
        'name': a.name,
        // 携带歌手自身 coverId，供歌手详情页/参与歌手列表显示歌手图片
        if (a.coverId != null && a.coverId!.isNotEmpty)
          'coverId': a.coverId,
      }).toList(),
    );
    final albumJson = jsonEncode({
      'guid': track.album.guid,
      'name': track.album.name,
      if (track.album.coverId != null) 'coverId': track.album.coverId,
    });

    String specText = '';
    if (track.audioSpec != null) {
      final parts = <String>[];
      if (track.audioSpec!.format != null && track.audioSpec!.format!.isNotEmpty) {
        parts.add(track.audioSpec!.format!.toUpperCase());
      }
      if (track.audioSpec!.sampleRate != null && track.audioSpec!.sampleRate! > 0) {
        parts.add('${(track.audioSpec!.sampleRate! / 1000).toStringAsFixed(1)}kHz');
      }
      if (track.audioSpec!.bitDepth != null && track.audioSpec!.bitDepth! > 0) {
        parts.add('${track.audioSpec!.bitDepth}bit');
      }
      if (track.audioSpec!.bitrate != null && track.audioSpec!.bitrate! > 0) {
        parts.add('${(track.audioSpec!.bitrate! / 1000).toStringAsFixed(0)}kbps');
      }
      specText = parts.join(' ');
    }

    return SongEntity(
      id: track.guid,
      title: track.title,
      artist: artistsJson,
      album: albumJson,
      uri: _api.streamUrl(track.guid),
      headersJson: jsonEncode(FeiNiuApiClient.instance.authHeaders()),
      durationMs: track.duration,
      bitrate: track.audioSpec?.bitrate,
      sampleRate: track.audioSpec?.sampleRate,
      format: track.audioSpec?.format,
      codec: track.audioSpec?.codec,
      fileSize: track.audioSpec?.size,
      isFavorite: track.isFavorite,
      coverId: track.coverId,
      audioSpec: specText,
      trackNumber: track.trackNo,
      discNumber: track.discNo,
      updatedAt: track.updatedAt,
      isCue: track.isCue,
      isAudioFileDeleted: track.isAudioFileDeleted,
    );
  }

  /// 从原始 Map 转为 SongEntity（用于 trackToSongEntity 方法）
  SongEntity _fromTrackMap(Map<String, dynamic> t) {
    return _feiNiuTrackToEntity(FeiNiuTrack.fromJson(t));
  }
}
