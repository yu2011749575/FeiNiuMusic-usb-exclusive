import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/song_state.dart';

void main() {
  group('SongEntity codec 字段', () {
    test('fromMap/toMap 往返保留 codec', () {
      final song = SongEntity.fromMap({
        'id': 's1',
        'title': '我等你',
        'artist': '[{"name":"刘若英"}]',
        'format': 'm4a',
        'codec': 'eac3',
      });
      expect(song.format, 'm4a');
      expect(song.codec, 'eac3');
      expect(song.toMap()['codec'], 'eac3');
    });

    test('codec 缺失时 fromMap 为 null', () {
      final song = SongEntity.fromMap({
        'id': 's2',
        'title': 't',
        'artist': 'a',
        'format': 'mp3',
      });
      expect(song.codec, isNull);
    });

    test('copyWith 保留 codec', () {
      final song = SongEntity(
        id: 's3',
        title: 't',
        artist: 'a',
        format: 'm4a',
        codec: 'alac',
      );
      final copied = song.copyWith(title: '新标题');
      expect(copied.codec, 'alac');
    });

    test('copyWith 可更新 codec', () {
      final song = SongEntity(
        id: 's4',
        title: 't',
        artist: 'a',
        format: 'm4a',
      );
      final updated = song.copyWith(codec: 'eac3');
      expect(updated.codec, 'eac3');
    });
  });

  group('SongEntity album 字段', () {
    test('albumCoverId 解析 album JSON 中的 coverId', () {
      final song = SongEntity.fromMap({
        'id': 's5',
        'title': 't',
        'artist': 'a',
        'album': '{"guid":"abc","name":"专辑","coverId":"album_def"}',
      });
      expect(song.albumCoverId, 'album_def');
    });

    test('albumCoverId 缺 coverId / 非 JSON 时返回 null', () {
      final noCover = SongEntity.fromMap({
        'id': 's6',
        'title': 't',
        'artist': 'a',
        'album': '{"guid":"abc","name":"专辑"}',
      });
      expect(noCover.albumCoverId, isNull);

      final plain = SongEntity.fromMap({
        'id': 's7',
        'title': 't',
        'artist': 'a',
        'album': '纯文本专辑',
      });
      expect(plain.albumCoverId, isNull);
      expect(plain.albumGuid, isNull);
    });
  });
}
