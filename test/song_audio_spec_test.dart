import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/app/utils/song_audio_spec.dart';

void main() {
  test('FLAC displays only source format and bitrate', () {
    const song = SongEntity(
      id: 'flac',
      title: 'FLAC',
      artist: '',
      format: 'flac',
      sampleRate: 96000,
      bitrate: 2850000,
      audioSpec: 'FLAC 96.0kHz 24bit 2850kbps',
    );
    expect(formatSongAudioSpec(song), 'FLAC · 2,850 kbps');
    expect(
      formatSongAudioSpec(SongEntity.fromMap(song.toMap())),
      formatSongAudioSpec(song),
    );
  });

  test('AAC uses known codec instead of its M4A container', () {
    const song = SongEntity(
      id: 'aac',
      title: '',
      artist: '',
      format: 'm4a',
      codec: ' aac ',
      sampleRate: 44100,
      bitrate: 256000,
    );
    expect(formatSongAudioSpec(song), 'AAC · 256 kbps');
  });

  test('legacy queue entries retain their format and bitrate', () {
    const song = SongEntity(
      id: 'legacy',
      title: '',
      artist: '',
      audioSpec: 'flac 44.1kHz 16bit 900kbps',
    );
    expect(formatSongAudioSpec(song), 'FLAC · 900 kbps');
  });

  test('structured bitrate overrides rounded legacy value', () {
    const song = SongEntity(
      id: 'precise',
      title: '',
      artist: '',
      format: 'wav',
      sampleRate: 11025,
      bitrate: 352800,
      audioSpec: 'WAV 11.0kHz 16bit 353kbps',
    );
    expect(formatSongAudioSpec(song), 'WAV · 353 kbps');
  });

  test('missing and invalid metadata are omitted', () {
    expect(formatSongAudioSpec(null), isEmpty);
    expect(
      formatSongAudioSpec(
        const SongEntity(
          id: 'empty',
          title: '',
          artist: '',
          sampleRate: 0,
          bitrate: -1,
          format: ' ',
          codec: '',
          audioSpec: '0kHz -16bit 0kbps',
        ),
      ),
      isEmpty,
    );
    expect(
      formatSongAudioSpec(
        const SongEntity(id: 'partial', title: '', artist: '', format: 'mp3'),
      ),
      'MP3',
    );
    expect(
      formatSongAudioSpec(
        const SongEntity(
          id: 'malformed',
          title: '',
          artist: '',
          audioSpec: '{bad json}',
        ),
      ),
      isEmpty,
    );
  });

  test('player text distinguishes direct source from transcoded output', () {
    const song = SongEntity(
      id: 'dsf',
      title: '',
      artist: '',
      format: 'dsf',
      bitrate: 5645000,
    );
    expect(formatPlayerAudioSpec(song), 'DSF · 5,645 kbps · 直连');
    expect(
      formatPlayerAudioSpec(song, playbackCodec: 'mp3'),
      '原始：DSF · 5,645 kbps\n播放：MP3 · 转码',
    );
    expect(
      formatPlayerAudioSpec(
        const SongEntity(id: 'unknown', title: '', artist: ''),
        playbackCodec: 'opus',
      ),
      '播放：OPUS · 转码',
    );
  });
}
