import 'dart:convert';

class SongEntity {
  final String id;
  final String title;
  final String artist; // JSON: [{"guid":"...","name":"..."}]
  final String? album; // JSON: {"guid":"...","name":"..."}
  final String? uri;
  final String? headersJson;
  final int? durationMs;
  final int? bitrate;
  final int? sampleRate;
  final int? fileSize;
  final String? format;
  final String? codec; // 音频编码（audioSpec.codec，如 eac3/alac/aac），路由层用于判断 ExoPlayer 是否可靠
  final bool isFavorite;
  final String? coverId;
  final String? audioSpec;
  final int? trackNumber;
  final int? discNumber;
  final int? updatedAt; // 服务端 updatedAt 时间戳，用于 CDN 缓存刷新
  final bool isCue;
  final int? cueOffsetMs; // CUE 整轨曲目在物理文件内的起始偏移（专辑上下文累计）
  final bool isAudioFileDeleted; // 失效歌曲（音频文件已删除）

  const SongEntity({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.uri,
    this.headersJson,
    this.durationMs,
    this.bitrate,
    this.sampleRate,
    this.fileSize,
    this.format,
    this.codec,
    this.isFavorite = false,
    this.coverId,
    this.audioSpec,
    this.trackNumber,
    this.discNumber,
    this.updatedAt,
    this.isCue = false,
    this.cueOffsetMs,
    this.isAudioFileDeleted = false,
  });

  /// 解析 artist JSON 获取歌手显示名
  String get artistDisplayName {
    try {
      final list = jsonDecode(artist) as List<dynamic>;
      return list
          .map((e) => (e as Map<String, dynamic>)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .join(' / ');
    } catch (_) {
      return artist;
    }
  }

  /// 解析第一个 artist 的 guid
  String? get firstArtistGuid {
    try {
      final list = jsonDecode(artist) as List<dynamic>;
      if (list.isEmpty) return null;
      return (list.first as Map<String, dynamic>)['guid'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 解析全部 artist 的 guid 列表（供批量匹配回退原歌手用）。
  List<String> get artistGuids {
    try {
      final list = jsonDecode(artist) as List<dynamic>;
      return list
          .map((e) => (e as Map<String, dynamic>)['guid'] as String?)
          .whereType<String>()
          .where((g) => g.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 解析第一个 artist 的 coverId（歌手自身图片）。
  ///
  /// artist JSON 由 [FeiNiuTrackService] 写入，携带 `coverId` 字段
  /// （数据库/旧数据可能没有，返回 null）。
  String? get firstArtistCoverId {
    try {
      final list = jsonDecode(artist) as List<dynamic>;
      if (list.isEmpty) return null;
      return (list.first as Map<String, dynamic>)['coverId'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 解析 artist JSON 中指定 guid 歌手的 coverId（多歌手时精确匹配，
  /// 找不到返回 null）。
  String? artistCoverIdForGuid(String? guid) {
    if (guid == null || guid.isEmpty) return null;
    try {
      final list = jsonDecode(artist) as List<dynamic>;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        if (m['guid'] == guid) return m['coverId'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 解析 artist JSON 中指定名称歌手的 coverId（多歌手时按名精确匹配，
  /// 找不到返回 null）。
  String? artistCoverIdForName(String? name) {
    if (name == null || name.isEmpty) return null;
    try {
      final list = jsonDecode(artist) as List<dynamic>;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        if (m['name'] == name) return m['coverId'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 解析 artist JSON 中指定名称歌手的 guid（多歌手时按名精确匹配，
  /// 找不到返回 null）。
  String? artistGuidForName(String? name) {
    if (name == null || name.isEmpty) return null;
    try {
      final list = jsonDecode(artist) as List<dynamic>;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        if (m['name'] == name) return m['guid'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 解析 album JSON 获取专辑显示名
  String get albumDisplayName {
    try {
      final map = jsonDecode(album ?? '{}') as Map<String, dynamic>;
      return map['name'] as String? ?? album ?? '未知专辑';
    } catch (_) {
      return album ?? '未知专辑';
    }
  }

  /// 解析 album JSON 获取专辑 guid
  String? get albumGuid {
    if (album == null) return null;
    try {
      final map = jsonDecode(album!) as Map<String, dynamic>;
      return map['guid'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 解析 album JSON 获取专辑 coverId（track 的 album JSON 内嵌 coverId）。
  String? get albumCoverId {
    if (album == null) return null;
    try {
      final map = jsonDecode(album!) as Map<String, dynamic>;
      return map['coverId'] as String?;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'uri': uri,
      'isLocal': 0, // 永远是云端
      'headersJson': headersJson,
      'durationMs': durationMs,
      'bitrate': bitrate,
      'sampleRate': sampleRate,
      'fileSize': fileSize,
      'format': format,
      'codec': codec,
      'isFavorite': isFavorite ? 1 : 0,
      'coverId': coverId,
      'audioSpec': audioSpec,
      'trackNumber': trackNumber,
      'discNumber': discNumber,
      'updatedAt': updatedAt,
      'isCue': isCue ? 1 : 0,
      'cueOffsetMs': cueOffsetMs,
      'isAudioFileDeleted': isAudioFileDeleted ? 1 : 0,
    };
  }

  factory SongEntity.fromMap(Map<String, dynamic> map) {
    int? parseInt(dynamic v) {
      if (v is int) return v;
      return int.tryParse(v?.toString() ?? '');
    }

    return SongEntity(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '未知标题').toString(),
      artist: (map['artist'] ?? '未知歌手').toString(),
      album: map['album']?.toString(),
      uri: map['uri']?.toString(),
      headersJson: map['headersJson']?.toString(),
      durationMs: parseInt(map['durationMs']),
      bitrate: parseInt(map['bitrate']),
      sampleRate: parseInt(map['sampleRate']),
      fileSize: parseInt(map['fileSize']),
      format: map['format']?.toString(),
      codec: map['codec']?.toString(),
      isFavorite: map['isFavorite'] == true || map['isFavorite'] == 1,
      coverId: map['coverId']?.toString(),
      audioSpec: map['audioSpec']?.toString(),
      trackNumber: parseInt(map['trackNumber']),
      discNumber: parseInt(map['discNumber']),
      updatedAt: parseInt(map['updatedAt']),
      isCue: map['isCue'] == true || map['isCue'] == 1,
      cueOffsetMs: parseInt(map['cueOffsetMs']),
      isAudioFileDeleted:
          map['isAudioFileDeleted'] == true || map['isAudioFileDeleted'] == 1,
    );
  }

  SongEntity copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? uri,
    String? headersJson,
    int? durationMs,
    int? bitrate,
    int? sampleRate,
    int? fileSize,
    String? format,
    String? codec,
    bool? isFavorite,
    String? coverId,
    String? audioSpec,
    int? trackNumber,
    int? discNumber,
    int? updatedAt,
    bool? isCue,
    int? cueOffsetMs,
    bool? isAudioFileDeleted,
  }) {
    return SongEntity(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      uri: uri ?? this.uri,
      headersJson: headersJson ?? this.headersJson,
      durationMs: durationMs ?? this.durationMs,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      fileSize: fileSize ?? this.fileSize,
      format: format ?? this.format,
      codec: codec ?? this.codec,
      isFavorite: isFavorite ?? this.isFavorite,
      coverId: coverId ?? this.coverId,
      audioSpec: audioSpec ?? this.audioSpec,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      updatedAt: updatedAt ?? this.updatedAt,
      isCue: isCue ?? this.isCue,
      cueOffsetMs: cueOffsetMs ?? this.cueOffsetMs,
      isAudioFileDeleted: isAudioFileDeleted ?? this.isAudioFileDeleted,
    );
  }
}
