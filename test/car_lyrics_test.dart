import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/media_notification_car_lyrics.dart';

void main() {
  group('carLyricsTitleOverride', () {
    test('开关关闭时返回 null（车机显示真实歌名）', () {
      expect(
        carLyricsTitleOverride(
          carLyricsEnabled: false,
          isCurrentSong: true,
          currentCarLyricLine: '我们不一样',
        ),
        isNull,
      );
    });

    test('非当前歌曲时返回 null（队列其他曲目保持真实歌名）', () {
      expect(
        carLyricsTitleOverride(
          carLyricsEnabled: true,
          isCurrentSong: false,
          currentCarLyricLine: '我们不一样',
        ),
        isNull,
      );
    });

    test('歌词行为 null / 空 / 纯空白时返回 null', () {
      for (final line in [null, '', '   ', '\t\n']) {
        expect(
          carLyricsTitleOverride(
            carLyricsEnabled: true,
            isCurrentSong: true,
            currentCarLyricLine: line,
          ),
          isNull,
          reason: 'line=$line',
        );
      }
    });

    test('开启且为当前歌曲时返回 trim 后的歌词行', () {
      expect(
        carLyricsTitleOverride(
          carLyricsEnabled: true,
          isCurrentSong: true,
          currentCarLyricLine: '  我们不一样  ',
        ),
        '我们不一样',
      );
    });

    test('覆盖决策不依赖 showLyrics（开关独立）', () {
      // 该纯函数没有 showLyrics 入参，只受 carLyricsEnabled + isCurrentSong
      // + 歌词行驱动——锁定车载开关与「通知显示歌词」开关独立。
      final override = carLyricsTitleOverride(
        carLyricsEnabled: true,
        isCurrentSong: true,
        currentCarLyricLine: '人生短短几个秋',
      );
      expect(override, '人生短短几个秋');
    });
  });
}
