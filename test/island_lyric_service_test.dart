import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_lyric/core/lyric_model.dart' as fl;

import 'package:feiniu_music/app/services/island_lyric_service.dart';
import 'package:feiniu_music/app/state/settings_island_lyric.dart';

void main() {
  group('IslandLyricService.shouldShow', () {
    test('开关关闭时不显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: false,
          isPlaying: true,
          lyricLine: '歌词行',
        ),
        false,
      );
    });

    test('未在播放时不显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: true,
          isPlaying: false,
          lyricLine: '歌词行',
        ),
        false,
      );
    });

    test('无歌词行时不显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: true,
          isPlaying: true,
          lyricLine: null,
        ),
        false,
      );
    });

    test('播放中且有歌词时显示', () {
      expect(
        IslandLyricService.shouldShow(
          enabled: true,
          isPlaying: true,
          lyricLine: '歌词行',
        ),
        true,
      );
    });
  });

  group('IslandLyricService.shouldUpdate', () {
    test('首行歌词（上一行为空）更新', () {
      expect(
        IslandLyricService.shouldUpdate(previous: null, next: '第一行'),
        true,
      );
    });

    test('歌词行变化时更新', () {
      expect(
        IslandLyricService.shouldUpdate(previous: '第一行', next: '第二行'),
        true,
      );
    });

    test('歌词行未变化时不更新（去重）', () {
      expect(
        IslandLyricService.shouldUpdate(previous: '同一行', next: '同一行'),
        false,
      );
    });
  });

  group('IslandLyricService.simulateTestPayload', () {
    test('测试模式 payload：歌词循环 + 进度递增（0→100 后归零循环）', () {
      final p0 = IslandLyricService.simulateTestPayload(tick: 0, lyricCount: 4);
      // payload 里 lyric 是右半、leftLyric 是左半；空格作为分割点被丢弃，
      // 两侧各自干净显示（左=短语、右=序号）
      expect(p0['leftLyric'], '测试歌词');
      expect(p0['lyric'], '1/4');
      expect(p0['progress'], 0);

      final p3 = IslandLyricService.simulateTestPayload(tick: 3, lyricCount: 4);
      expect(p3['leftLyric'], '测试歌词');
      expect(p3['lyric'], '4/4');
      expect(p3['progress'], 75);

      // 循环：tick=4 回到第一行，进度归零
      final p4 = IslandLyricService.simulateTestPayload(tick: 4, lyricCount: 4);
      expect(p4['leftLyric'], '测试歌词');
      expect(p4['lyric'], '1/4');
      expect(p4['progress'], 0);
    });

    test('测试模式 payload 始终 isPlaying=true（模拟播放中）', () {
      final p = IslandLyricService.simulateTestPayload(tick: 1, lyricCount: 2);
      expect(p['isPlaying'], true);
      expect(p['title'], '灵动岛测试');
    });
  });

  group('IslandLyricService notificationType', () {
    test('buildUpdatePayload 携带通知类型（默认实时通知）', () {
      final p = IslandLyricService.buildUpdatePayload(
        fullLyric: '测试歌词',
        title: '测试歌曲',
        artist: '歌手',
        isPlaying: true,
        positionMs: 1000,
        durationMs: 60000,
        showProgress: true,
        coverPath: null,
        aodLyrics: false,
      );
      expect(
        p['notificationType'],
        IslandLyricSettings.typeLive,
        reason: '默认应透传实时通知类型',
      );
    });
  });

  group('IslandLyricService.buildUpdatePayload', () {
    test('payload 含完整歌词帧（fullLyric = 当前帧左+右拼接）', () {
      const frame = '聆听山语 回荡不清';
      final p = IslandLyricService.buildUpdatePayload(
        fullLyric: frame,
        title: '测试歌曲',
        artist: '歌手',
        isPlaying: true,
        positionMs: 1000,
        durationMs: 60000,
        showProgress: true,
        coverPath: null,
        aodLyrics: true,
      );
      expect(p['fullLyric'], frame, reason: 'fullLyric 应为完整歌词帧，供息屏标题使用');
    });

    test('payload 无 fullLyric 时（aodLyrics 关）不影响其它字段', () {
      final p = IslandLyricService.buildUpdatePayload(
        fullLyric: '短歌词',
        title: '测试歌曲',
        artist: '歌手',
        isPlaying: false,
        positionMs: 0,
        durationMs: 60000,
        showProgress: false,
        coverPath: 'cover.jpg',
        aodLyrics: false,
      );
      expect(p['title'], '测试歌曲');
      expect(p['aodLyrics'], false);
      expect(p['coverPath'], 'cover.jpg');
    });
  });

  group('IslandLyricService.splitLyricForIsland', () {
    test('短歌词也左右拼接：两侧非空且拼成完整歌词', () {
      const lyric = '短歌词';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty, reason: '短歌词左侧也应有内容');
      expect(r.right, isNotEmpty, reason: '短歌词右侧也应有内容');
      expect('${r.left}${r.right}', lyric, reason: '左右拼接等于完整歌词');
    });

    test('短歌词均分：两侧字符数差不超过 1', () {
      const lyric = '短歌词';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect((r.left.length - r.right.length).abs(), lessThanOrEqualTo(1),
          reason: '短歌词应按字符均分，两侧接近等长');
    });

    test('2字帧：左右各 1 字（不整段只放一侧）', () {
      const lyric = 'XX';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, 'X', reason: '2字帧左侧应恰好 1 字');
      expect(r.right, 'X', reason: '2字帧右侧应恰好 1 字');
    });

    test('空格分隔的短语：在空格处断，两侧不带头尾空格', () {
      const lyric = '聆听山语 回荡不清';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, '聆听山语', reason: '左半应在空格处断，不带空格');
      expect(r.right, '回荡不清', reason: '右半应在空格处断，不带空格');
      expect(r.left.trim(), r.left, reason: '左侧不带头尾空格');
      expect(r.right.trim(), r.right, reason: '右侧不带头尾空格');
    });

    test('奇数帧：右侧多 1 字（ceil 均分）', () {
      const lyric = '三字词';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left.runes.length, 2, reason: '3字帧左侧 2 字');
      expect(r.right.runes.length, 1, reason: '3字帧右侧 1 字');
      expect('${r.left}${r.right}', lyric);
    });

    test('长歌词：按长度对半分割，左右衔接拼成完整歌词', () {
      const lyric = '这是一段比较长的歌词用来测试左右分割衔接的效果';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty);
      expect(r.right, isNotEmpty);
      // 左右拼接起来应等于完整歌词（衔接）
      expect('${r.left}${r.right}', lyric);
    });

    test('空歌词：两侧皆空', () {
      final r = IslandLyricService.splitLyricForIsland('');
      expect(r.left, isEmpty);
      expect(r.right, isEmpty);
    });

    test('超长歌词：同样左右拼接，两侧同时非空', () {
      const lyric = '这是一行特别长的歌词用来测试滚动接力效果的显示方式';
      final r = IslandLyricService.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty, reason: '超长歌词左侧也应有内容');
      expect(r.right, isNotEmpty, reason: '超长歌词右侧也应有内容');
      expect('${r.left}${r.right}', lyric, reason: '超长歌词也应左右拼接成完整歌词');
    });
  });

  group('IslandLyricService.shouldSendCover', () {
    test('同一首歌同一封面：不需要重发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's1',
          newCoverId: 'c1',
        ),
        false,
      );
    });

    test('切歌到新封面：需要发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's2',
          newCoverId: 'c2',
        ),
        true,
      );
    });

    test('同一首歌封面变化（updatedAt 刷新）：需要发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's1',
          newCoverId: 'c2',
        ),
        true,
      );
    });

    test('无封面 id：不发封面', () {
      expect(
        IslandLyricService.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: null,
          newSongId: 's2',
          newCoverId: null,
        ),
        false,
      );
    });
  });

  group('IslandLyricService.chunkLyric', () {
    test('短歌词（≤10字）：单帧（整行）', () {
      const lyric = '短歌词';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, 1);
      expect(frames.single, lyric);
    });

    test('超长歌词：拆成多帧，每帧不超过 frameChars', () {
      const lyric = '这是一行特别长的歌词用来测试滚动接力效果的显示方式';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, greaterThan(1));
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(10),
            reason: '每帧应不超过单帧容量');
      }
      // 所有帧拼接 = 完整歌词（无丢失）
      expect(frames.join(), lyric);
    });

    test('智能截断：优先在空格词边界断，短词不被切散', () {
      // 空格分隔的短词（≤10字）应保持完整，不被切散
      const lyric = '今天天气很好 我们去爬山 明天再出发';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      // 每个空格分隔的词都完整出现在某一帧里（不被切散）
      expect(frames.join(' ').contains('今天天气很好'), isTrue);
      expect(frames.join(' ').contains('我们去爬山'), isTrue);
      expect(frames.join(' ').contains('明天再出发'), isTrue);
      // 帧内不含空格（空格作为断点被消费，不留在帧首尾）
      for (final frame in frames) {
        expect(frame.contains(' '), isFalse, reason: '帧内不应含空格');
        expect(frame.trim(), frame, reason: '帧不应含首尾空格');
      }
    });

    test('智能截断：超长 ASCII 单词本身必须被切（无法整词保留）', () {
      const lyric = 'Supercalifragilistic';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, greaterThan(1), reason: '超长单词应被切成多帧');
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(10),
            reason: '即使切单词，每帧也不超过 10 字');
      }
      expect(frames.join(), lyric, reason: '拼接等于完整单词');
    });

    test('恰好 10 字：单帧', () {
      const lyric = '一二三四五六七八九十';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, 1);
      expect(frames.single, lyric);
    });

    test('实时通知 7 字截断：空格优先断点，首帧不超 7 字', () {
      // 空格分隔：优先在空格断，首帧 = 空格前的完整词
      const lyric = '今天天气很好 我们去爬山';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 7);
      expect(frames.length, greaterThan(1), reason: '超长行应拆多帧');
      expect(frames.first, '今天天气很好', reason: '首帧应取空格前的完整词');
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(7),
            reason: '每帧不超过 7 字');
      }
      // 无空格：按 7 字硬切，首帧 = 前 7 字
      const noSpace = '这是一首超长的歌没有空格';
      final nf = IslandLyricService.chunkLyric(noSpace, frameChars: 7);
      expect(nf.first, '这是一首超长的', reason: '无空格时首帧取前 7 字');
    });

    test('拆帧过滤分隔符：空格、连字符、间隔号不留在帧内', () {
      // 连字符分隔：断点优先在连字符，且连字符被过滤
      const hyphen = '旧梦前尘-一去不回';
      final hf = IslandLyricService.chunkLyric(hyphen, frameChars: 7);
      expect(hf.length, greaterThan(1), reason: '连字符分隔的超长行应拆多帧');
      expect(hf.first, '旧梦前尘', reason: '首帧应为连字符前的完整词，且不含连字符');
      expect(hf.any((f) => f.contains('-')), isFalse, reason: '帧内不应含连字符');

      // 间隔号分隔：同样作为断点并被过滤
      const middot = '半山听雨·夜雨声烦';
      final mf = IslandLyricService.chunkLyric(middot, frameChars: 7);
      expect(mf.any((f) => f.contains('·')), isFalse, reason: '帧内不应含间隔号');
      expect(mf.join(), '半山听雨夜雨声烦', reason: '去掉间隔号后拼接等于过滤后的完整歌词');
    });

    test('拆帧不含尾随空格（避免空格留在帧尾导致滚动）', () {
      const lyric = '聆听山语 回荡不清 若即若离';
      final frames = IslandLyricService.chunkLyric(lyric, frameChars: 10);
      for (final frame in frames) {
        expect(frame.trim(), frame, reason: '帧不应含首尾空格');
      }
      // 去掉空格后拼接仍等于原词（空格作为分隔符丢弃）
      final joined = frames.map((f) => f.trim()).join();
      expect(joined.replaceAll(' ', ''), '聆听山语回荡不清若即若离');
    });

    test('空歌词：无帧', () {
      final frames = IslandLyricService.chunkLyric('', frameChars: 10);
      expect(frames, isEmpty);
    });
  });

  group('IslandLyricService.frameIndexForPosition', () {
    // 行时间窗口 [2000ms, 4000ms]，两帧：帧0=[2000,3000)，帧1=[3000,4000)
    test('位置在行开始前：第 0 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 1000,
        ),
        0,
      );
    });

    test('位置在前半段（中点前）：第 0 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 2500,
        ),
        0,
      );
    });

    test('位置在后半段（中点后）：第 1 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 3500,
        ),
        1,
      );
    });

    test('位置在行结束后：最后一帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 99999,
        ),
        1,
      );
    });

    test('单帧或无 end：恒第 0 帧', () {
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 1,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 3500,
        ),
        0,
      );
      expect(
        IslandLyricService.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: null,
          positionMs: 3500,
        ),
        0,
      );
    });
  });

  group('IslandLyricService.frameIndexForPositionWithWords', () {
    const frames = ['旧梦前尘', '一去不回'];

    test('无逐字时间戳：退回等分逻辑', () {
      expect(
        IslandLyricService.frameIndexForPositionWithWords(
          frames: frames,
          words: null,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 3000,
        ),
        0,
      );
      expect(
        IslandLyricService.frameIndexForPositionWithWords(
          frames: frames,
          words: null,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 5000,
        ),
        1,
      );
    });

    test('逐字时间戳：唱到后半段立即翻帧（不等到行结束）', () {
      // 「旧梦前尘」(2000-4000) 是前半帧，「一去不回」从 4000ms 开始（后半帧）
      final List<fl.LyricWord> words = [
        fl.LyricWord(text: '旧', start: Duration(milliseconds: 2000), end: Duration(milliseconds: 2500)),
        fl.LyricWord(text: '梦', start: Duration(milliseconds: 2500), end: Duration(milliseconds: 3000)),
        fl.LyricWord(text: '前', start: Duration(milliseconds: 3000), end: Duration(milliseconds: 3500)),
        fl.LyricWord(text: '尘', start: Duration(milliseconds: 3500), end: Duration(milliseconds: 4000)),
        fl.LyricWord(text: '一', start: Duration(milliseconds: 4000), end: Duration(milliseconds: 4500)),
        fl.LyricWord(text: '去', start: Duration(milliseconds: 4500), end: Duration(milliseconds: 5000)),
        fl.LyricWord(text: '不', start: Duration(milliseconds: 5000), end: Duration(milliseconds: 5500)),
        fl.LyricWord(text: '回', start: Duration(milliseconds: 5500), end: Duration(milliseconds: 6000)),
      ];
      // 行开始前 → 0
      expect(
        IslandLyricService.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 1500,
        ),
        0,
      );
      // 唱到「旧」(2000) → 帧 0
      expect(
        IslandLyricService.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 2000,
        ),
        0,
      );
      // 唱到「尘」末尾 / 「一」开始 (4000) → 翻到帧 1（后半段）
      expect(
        IslandLyricService.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 4000,
        ),
        1,
      );
      // 行结束后 → 最后一帧
      expect(
        IslandLyricService.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 99999,
        ),
        1,
      );
    });

    test('逐字行 end 为 null：仍能按字推进（不退回第 0 帧）', () {
      final List<fl.LyricWord> words = [
        fl.LyricWord(text: '一', start: Duration(milliseconds: 2000), end: Duration(milliseconds: 3000)),
        fl.LyricWord(text: '去', start: Duration(milliseconds: 3000), end: Duration(milliseconds: 4000)),
      ];
      expect(
        IslandLyricService.frameIndexForPositionWithWords(
          frames: ['一', '去'],
          words: words,
          lineStartMs: 2000,
          lineEndMs: null, // 行无结束时间
          positionMs: 3500, // 唱到「去」后半
        ),
        1,
      );
    });
  });

  group('IslandCapabilities 能力探测解析', () {
    test('解析原生层返回的 map（支持岛 + 焦点通知 + Android 16+）', () {
      final caps = IslandCapabilities.fromMap({
        'supportIsland': true,
        'focusProtocol': 3,
        'focusPermission': true,
        'focusEnabled': true,
        'androidSdk': 36,
      });
      expect(caps.supportIsland, isTrue);
      expect(caps.focusProtocol, 3);
      expect(caps.focusPermission, isTrue);
      expect(caps.focusEnabled, isTrue);
      expect(caps.liveEnabled, isTrue, reason: 'Android 16（API 36）以上实时通知可用');
    });

    test('Android <16 时实时通知不可用，焦点通知不受影响', () {
      final caps = IslandCapabilities.fromMap({
        'supportIsland': true,
        'focusProtocol': 3,
        'focusPermission': true,
        'focusEnabled': true,
        'androidSdk': 35,
      });
      expect(caps.liveEnabled, isFalse, reason: 'Android 15 不支持实时通知');
      expect(caps.focusEnabled, isTrue, reason: '焦点通知需 HyperOS 2/OS2+ + 权限，与 Android 版本无关');
    });

    test('OS1 协议不支持、权限未开、缺字段按不可用兜底', () {
      final os1 = IslandCapabilities.fromMap({
        'supportIsland': false,
        'focusProtocol': 1,
        'focusPermission': true,
        'focusEnabled': false,
        'androidSdk': 36,
      });
      expect(os1.focusEnabled, isFalse, reason: 'OS1 为旧版焦点模板，不支持');

      final noPerm = IslandCapabilities.fromMap({
        'supportIsland': true,
        'focusProtocol': 3,
        'focusPermission': false,
        'focusEnabled': false,
        'androidSdk': 36,
      });
      expect(noPerm.focusEnabled, isFalse, reason: '焦点通知权限未开启则不可用');
    });

    test('OS2 协议（focusProtocol=2）也支持焦点通知', () {
      final os2 = IslandCapabilities.fromMap({
        'supportIsland': true,
        'focusProtocol': 2,
        'focusPermission': true,
        'focusEnabled': false,
        'androidSdk': 36,
      });
      expect(os2.focusEnabled, isTrue, reason: 'OS2 支持焦点通知（模板与 OS3 不同），只要协议>=2 且权限开启');

      // 协议>=2 时是否支持岛不影响焦点通知可用性
      final os2NoIsland = IslandCapabilities.fromMap({
        'supportIsland': false,
        'focusProtocol': 2,
        'focusPermission': true,
        'focusEnabled': false,
        'androidSdk': 36,
      });
      expect(os2NoIsland.focusEnabled, isTrue, reason: 'OS2 无岛渲染也能用焦点通知');
    });

    test('缺字段 / 探测失败按不支持兜底', () {
      const none = IslandCapabilities.none;
      expect(none.supportIsland, isFalse);
      expect(none.focusProtocol, 0);
      expect(none.focusPermission, isFalse);
      expect(none.focusEnabled, isFalse);
      expect(none.liveEnabled, isFalse, reason: 'androidSdk=0 时实时通知不可用');

      final empty = IslandCapabilities.fromMap(const {});
      expect(empty.focusEnabled, isFalse);
      expect(empty.liveEnabled, isFalse);
    });
  });
}
