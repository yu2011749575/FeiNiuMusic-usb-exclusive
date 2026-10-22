import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player/player_engine.dart';
import 'package:feiniu_music/app/services/player/playback_router.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 构造带 format/codec 的歌曲（两者都显式给值 → routeForSong 零网络开销）。
SongEntity _song(String id, {String? format, String? codec}) {
  return SongEntity(
    id: id,
    title: 't',
    artist: '[{"name":"a"}]',
    format: format,
    codec: codec,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('routeForFormat（codec 感知）', () {
    test('M4A + EAC3 → mediaKit（本次无声 bug 场景）', () {
      expect(
        routeForFormat('m4a', codec: 'eac3'),
        EngineKind.mediaKit,
        reason: 'EAC3 的 M4A 应交给 media_kit（FFmpeg）必出声',
      );
    });

    test('M4A + ALAC → mediaKit', () {
      expect(
        routeForFormat('m4a', codec: 'alac'),
        EngineKind.mediaKit,
      );
    });

    test('M4A + AAC → justAudio（系统解码，不变）', () {
      expect(
        routeForFormat('m4a', codec: 'aac'),
        EngineKind.justAudio,
      );
    });

    test('M4A + codec 未知 → justAudio（保持现状，交给无声看门狗兜底）', () {
      expect(
        routeForFormat('m4a'),
        EngineKind.justAudio,
      );
      expect(
        routeForFormat('m4a', codec: null),
        EngineKind.justAudio,
      );
    });

    test('format 黑名单仍生效：dsf 即使 codec=aac 也走 mediaKit', () {
      expect(
        routeForFormat('dsf', codec: 'aac'),
        EngineKind.mediaKit,
      );
    });

    test('codec 大小写不敏感', () {
      expect(routeForFormat('m4a', codec: 'EAC3'), EngineKind.mediaKit);
      expect(routeForFormat('m4a', codec: 'Ac3'), EngineKind.mediaKit);
    });

    test('普通格式（flac/mp3/ogg）+ 普通 codec → justAudio', () {
      expect(routeForFormat('flac', codec: 'flac'), EngineKind.justAudio);
      expect(routeForFormat('mp3', codec: 'mp3'), EngineKind.justAudio);
      expect(routeForFormat('ogg', codec: 'vorbis'), EngineKind.justAudio);
    });

    test('null/空 format + 普通 codec → justAudio', () {
      expect(routeForFormat(null, codec: 'aac'), EngineKind.justAudio);
      expect(routeForFormat('', codec: 'aac'), EngineKind.justAudio);
    });
  });

  group('routeForSong', () {
    test('M4A + EAC3 歌曲 → mediaKit（零网络）', () async {
      final kind = await routeForSong(_song('r1', format: 'm4a', codec: 'eac3'));
      expect(kind, EngineKind.mediaKit);
    });

    test('M4A + AAC 歌曲 → justAudio（零网络）', () async {
      final kind = await routeForSong(_song('r2', format: 'm4a', codec: 'aac'));
      expect(kind, EngineKind.justAudio);
    });
  });
}
