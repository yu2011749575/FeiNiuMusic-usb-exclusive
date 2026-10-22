import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/settings_player_style_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/player/widgets/player_bottom_panel.dart';

const _song = SongEntity(
  id: 'song-1',
  title: 'Test track',
  artist: 'Test artist',
);

/// 海报模式歌词页没有独立的定时按钮，定时入口改由「更多」面板提供。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlayerStyleSettings.ensureLoaded();
    PlayerStyleSettings.stylePreset.value = PlayerStylePreset.poster;
  });

  tearDown(() {
    PlayerService.instance.cancelSleepTimer();
    PlayerService.instance.currentSong.value = null;
    PlayerStyleSettings.stylePreset.value = PlayerStylePreset.classic;
  });

  testWidgets('海报歌词页「更多」面板可打开定时关闭', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = PlayerService.instance;
    player.currentSong.value = _song;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PosterControls(player: player)),
      ),
    );

    // 海报歌词页「更多」按钮（PosterControls 内与封面侧同一个入口）。
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('定时关闭'), findsOneWidget);
    expect(find.text('到达设定时间后自动停止播放'), findsOneWidget);

    await tester.tap(find.text('定时关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 「更多」面板让位给定时面板，两者不叠加。
    expect(find.text('下一首播放'), findsNothing);
    expect(find.text('定时'), findsOneWidget);
    expect(find.text('定时时长'), findsOneWidget);
    expect(find.text('播完整首歌后关闭'), findsOneWidget);

    await tester.tap(find.text('开始定时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.isSleepTimerActive, isTrue);

    // 定时器是 1 秒心跳，测试结束前先取消，避免残留 pending timer。
    player.cancelSleepTimer();
    await tester.pump();
  });
}
