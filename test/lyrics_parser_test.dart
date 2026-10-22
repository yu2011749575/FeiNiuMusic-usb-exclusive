import 'package:flutter_lyric/core/lyric_model.dart' as fl;
import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/lyrics/lyrics_parser.dart';

void main() {
  test('parse translation line with same timestamp', () {
    const lrc = '''
[00:02.392]Ave [00:02.574]Maria [00:04.301]grazia [00:04.589]ricevuta [00:06.145]per [00:06.318]la [00:06.535]mia [00:06.710]famiglia[00:07.285]
[00:02.392]\u4e07\u798f\u739b\u5229\u4e9a \u611f\u8c22\u60a8\u5bf9\u4e8e\u6211\u5bb6\u65cf\u7684\u6069\u8d50[00:15.340]
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    final line = model.lines.firstWhere(
      (l) => l.start == const Duration(milliseconds: 2392),
    );
    expect(
      line.translation,
      '\u4e07\u798f\u739b\u5229\u4e9a \u611f\u8c22\u60a8\u5bf9\u4e8e\u6211\u5bb6\u65cf\u7684\u6069\u8d50',
    );
  });

  test('parse enhanced translation line with same start timestamp', () {
    const lrc = '''
[00:01.000]Hello [00:01.500]world[00:02.000]
[00:01.000]\u4f60\u597d[00:01.500]\u4e16\u754c[00:02.000]
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    final line = model.lines.firstWhere(
      (l) => l.start == const Duration(seconds: 1),
    );
    expect(line.text, 'Hello world');
    expect(line.translation, '\u4f60\u597d\u4e16\u754c');
    expect(line.words?.map((w) => w.text).join(), 'Hello world');
  });

  fl.LyricLine lineAt(String lrc, Duration t) {
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    return model.lines.firstWhere((l) => l.start == t);
  }

  test(
    'chinese-original song keeps original as main, foreign as translation',
    () {
      // Same timestamp; original is Han-only, translation is latin. Must NOT swap.
      const lrc = '''
[00:10.00]\u6211\u4eec\u4e0d\u518d\u8054\u7cfb
[00:10.00]We are no longer in touch
''';
      final line = lineAt(lrc, const Duration(seconds: 10));
      expect(line.text, '\u6211\u4eec\u4e0d\u518d\u8054\u7cfb');
      expect(line.translation, 'We are no longer in touch');
    },
  );

  test('translation containing latin characters is still detected', () {
    const lrc = '''
[00:12.00]I love you
[00:12.00]\u6211\u7231\u4f60 baby
''';
    final line = lineAt(lrc, const Duration(seconds: 12));
    expect(line.text, 'I love you');
    expect(line.translation, '\u6211\u7231\u4f60 baby');
  });

  test('same-script (zh/zh) translation is detected', () {
    const lrc = '''
[00:05.00]\u5173\u5173\u96ce\u9e20
[00:05.00]\u96ce\u9e20\u9e1f\u5173\u5173\u548c\u5531
''';
    final line = lineAt(lrc, const Duration(seconds: 5));
    expect(line.text, '\u5173\u5173\u96ce\u9e20');
    expect(line.translation, '\u96ce\u9e20\u9e1f\u5173\u5173\u548c\u5531');
  });

  test('near-timestamp translation (rounding) is merged', () {
    const lrc = '''
[00:10.00]I love you
[00:10.01]\u6211\u7231\u4f60
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    expect(model.lines.length, 1);
    expect(model.lines.first.text, 'I love you');
    expect(model.lines.first.translation, '\u6211\u7231\u4f60');
  });

  test('exact-duplicate line is not turned into a translation', () {
    const lrc = '''
[00:03.00]la la la
[00:03.00]la la la
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    final line = model.lines.firstWhere(
      (l) => l.start == const Duration(seconds: 3),
    );
    expect(line.text, 'la la la');
    expect(line.translation, isNull);
  });

  test('offset-timestamp chinese translation is merged (译 button appears)', () {
    // Translation stamped shortly after the original (beyond same-time
    // tolerance) must still fold into the original as its translation.
    const lrc = '''
[00:12.00]あいしてる
[00:12.50]我爱你
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    expect(model.lines.length, 1);
    expect(model.lines.first.text, 'あいしてる');
    expect(model.lines.first.translation, '我爱你');
  });

  test('two consecutive non-chinese lines are NOT merged as translation', () {
    const lrc = '''
[00:12.00]I love you
[00:12.30]So do I
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    expect(model.lines.length, 2);
    expect(model.lines.every((l) => l.translation == null), isTrue);
  });

  test('two consecutive chinese lines are NOT merged as translation', () {
    const lrc = '''
[00:12.00]关关雎鸠
[00:12.20]在河之洲
''';
    final model = LyricsParser.buildModelFromRaw(
      lrc,
      predictDuration: false,
      forceKaraoke: false,
    );
    expect(model.lines.length, 2);
    expect(model.lines.every((l) => l.translation == null), isTrue);
  });

  test('typographic spaces split inline english/chinese translation', () {
    const separators = <String>[
      '\u00A0', // no-break space
      '\u2005', // four-per-em space
      '\u2009', // thin space (used by Don't Be So Serious)
      '\u202F', // narrow no-break space
      '\u3000', // ideographic space
    ];

    for (final separator in separators) {
      final model = LyricsParser.buildModelFromRaw(
        '[00:27.76]Weight$separator沉重\n'
        '[00:30.76]Heavy bones$separator沉重的身体',
        predictDuration: false,
        forceKaraoke: false,
      );

      expect(
        model.lines.length,
        2,
        reason:
            'separator U+'
            '${separator.codeUnitAt(0).toRadixString(16).toUpperCase()}',
      );
      expect(model.lines.first.text, 'Weight');
      expect(model.lines.first.translation, '沉重');
      expect(model.lines.last.text, 'Heavy bones');
      expect(model.lines.last.translation, '沉重的身体');
      expect(
        model.lines.any((line) => (line.translation ?? '').trim().isNotEmpty),
        isTrue,
      );
    }
  });
}
