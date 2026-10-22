import 'package:flutter_lyric/core/lyric_model.dart' as fl;
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/desktop_lyrics_service.dart';

void main() {
  final lines = <fl.LyricLine>[
    fl.LyricLine(
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 5),
      text: '  当前歌词  ',
    ),
    fl.LyricLine(
      start: const Duration(seconds: 5),
      end: const Duration(seconds: 9),
      text: '  下一行歌词  ',
    ),
  ];

  test('关闭开关或没有歌曲时不生成桌面歌词内容', () {
    expect(
      DesktopLyricsService.buildPayload(
        enabled: false,
        title: '歌名',
        lines: lines,
        activeIndex: 0,
        position: const Duration(seconds: 2),
      ),
      isNull,
    );
    expect(
      DesktopLyricsService.buildPayload(
        enabled: true,
        title: null,
        lines: lines,
        activeIndex: 0,
        position: const Duration(seconds: 2),
      ),
      isNull,
    );
  });

  test('生成当前行、下一行和播放进度', () {
    final payload = DesktopLyricsService.buildPayload(
      enabled: true,
      title: '歌名',
      lines: lines,
      activeIndex: 0,
      position: const Duration(seconds: 2),
    );

    expect(payload?['currentLine'], '当前歌词');
    expect(payload?['nextLine'], '下一行歌词');
    expect(payload?['progress'], 0.25);
    expect(payload?['karaoke'], isFalse);
  });

  test('逐字歌词按字的时间轴计算高亮进度', () {
    final line = fl.LyricLine(
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 5),
      text: '春风十里',
      words: [
        fl.LyricWord(
          text: '春风',
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 3),
        ),
        fl.LyricWord(
          text: '十里',
          start: const Duration(seconds: 3),
          end: const Duration(seconds: 5),
        ),
      ],
    );

    expect(
      DesktopLyricsService.progressForLine(
        line: line,
        position: const Duration(seconds: 4),
      ),
      0.75,
    );

    final payload = DesktopLyricsService.buildPayload(
      enabled: true,
      title: '歌名',
      lines: [line],
      activeIndex: 0,
      position: const Duration(seconds: 4),
    );
    expect(payload?['karaoke'], isTrue);
  });
}
