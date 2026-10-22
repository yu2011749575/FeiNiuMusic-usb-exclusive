import 'dart:convert';

import '../../state/song_state.dart';
import 'api_client.dart';
import 'api_models.dart';
import 'auth_service.dart';

/// 飞牛漫游服务（随机播放）
class FeiNiuRoamService {
  FeiNiuRoamService._();

  static final FeiNiuRoamService instance = FeiNiuRoamService._();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 获取随机起始曲目
  Future<SongEntity?> getRoamStart() async {
    final deviceId = await AuthService.instance.ensureDeviceId();
    final response = await _api.getRoamStart(deviceId);
    return _toSongEntity(response.current.track, _api.token);
  }

  /// 获取当前漫游的下一曲（带 roamId），同时返回更新后的完整状态
  Future<FeiNiuRoamNextResponse?> getRoamNextResponse(String roamId) async {
    final deviceId = await AuthService.instance.ensureDeviceId();
    return await _api.getRoamNext(deviceId, roamId);
  }

  /// 获取当前漫游 ID 的下一曲
  Future<SongEntity?> getRoamNext(String roamId) async {
    final deviceId = await AuthService.instance.ensureDeviceId();
    final response = await _api.getRoamNext(deviceId, roamId);
    if (response.next == null) return null;
    return _toSongEntity(response.next!.track, _api.token);
  }

  /// 获取漫游起始曲目的 roamId
  Future<String?> getRoamStartId() async {
    final deviceId = await AuthService.instance.ensureDeviceId();
    final response = await _api.getRoamStart(deviceId);
    return response.current.roamId;
  }

  SongEntity _toSongEntity(FeiNiuTrack track, String token) {
    final artistsJson = jsonEncode(
      track.artists.map((a) => {'guid': a.guid, 'name': a.name}).toList(),
    );
    final albumJson = jsonEncode({
      'guid': track.album.guid,
      'name': track.album.name,
    });

    String specText = '';
    if (track.audioSpec != null) {
      final parts = <String>[];
      final fmt = track.audioSpec!.format;
      final sr = track.audioSpec!.sampleRate;
      final bd = track.audioSpec!.bitDepth;
      if (fmt != null && fmt.isNotEmpty) parts.add(fmt.toUpperCase());
      if (sr != null && sr > 0) {
        parts.add('${(sr / 1000).toStringAsFixed(1)}kHz');
      }
      if (bd != null && bd > 0) parts.add('${bd}bit');
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
    );
  }
}
