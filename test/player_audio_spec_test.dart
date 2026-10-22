import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/state/settings_player_style_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/player/player_page.dart';
import 'package:feiniu_music/pages/player/widgets/player_audio_spec.dart';

const _flac = SongEntity(
  id: 'flac',
  title: 'Test track',
  artist: 'Test artist',
  format: 'flac',
  sampleRate: 96000,
  bitrate: 2850000,
  audioSpec: 'FLAC 96.0kHz 24bit 2850kbps',
);
const _label = 'FLAC · 2,850 kbps · 直连';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await PlayerStyleSettings.ensureLoaded();
  });

  testWidgets(
    'specification updates on song changes and hides without metadata',
    (tester) async {
      final song = ValueNotifier<SongEntity?>(_flac);
      final codec = ValueNotifier<String?>(null);
      addTearDown(song.dispose);
      addTearDown(codec.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerAudioSpec(
              songListenable: song,
              playbackCodecListenable: codec,
            ),
          ),
        ),
      );
      expect(find.text(_label), findsOneWidget);

      song.value = const SongEntity(
        id: 'aac',
        title: '',
        artist: '',
        codec: 'aac',
        bitrate: 256000,
      );
      await tester.pump();
      expect(find.text(_label), findsNothing);
      expect(find.text('AAC · 256 kbps · 直连'), findsOneWidget);

      codec.value = 'mp3';
      await tester.pump();
      expect(
        find.text('原始：AAC · 256 kbps\n播放：MP3 · 转码'),
        findsOneWidget,
      );

      codec.value = null;
      song.value = const SongEntity(id: 'unknown', title: '', artist: '');
      await tester.pump();
      expect(find.byType(Tooltip), findsNothing);
      expect(tester.getSize(find.byType(PlayerAudioSpec)), Size.zero);
      song.value = null;
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    },
  );

  testWidgets('narrow width and large text wrap without overflow', (
    tester,
  ) async {
      final song = ValueNotifier<SongEntity?>(_flac);
      final codec = ValueNotifier<String?>(null);
      addTearDown(song.dispose);
      addTearDown(codec.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 220,
              child: PlayerAudioSpec(
                songListenable: song,
                playbackCodecListenable: codec,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text(_label), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final style in PlayerStylePreset.values) {
    for (final size in [
      const Size(390, 844),
      // 上游海报控制按钮在 320px 宽时已有横向溢出；规格组件另测 220px 换行。
      Size(style == PlayerStylePreset.poster ? 360 : 320, 568),
      const Size(1280, 800),
    ]) {
      // 海报竖屏走 _PosterPlayerLayout，规格夹在收藏/队列按钮之间；
      // 横屏（含海报）走横屏布局底栏，规格仍在进度条下方。
      final inlineSpec =
          style == PlayerStylePreset.poster && size.width <= size.height;
      testWidgets(
        inlineSpec
            ? '$style $size: 规格位于进度条上方且夹在收藏与队列按钮之间'
            : '$style $size: audio specification appears below progress bar',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          AppLayoutSettings.resetForTest();
          PlayerStyleSettings.stylePreset.value = style;
          AppLayoutSettings.tabletMode.value = size.width > 900;
          final player = PlayerService.instance;
          player.currentSong.value = _flac;
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(() {
            tester.view.reset();
            player.currentSong.value = null;
            PlayerStyleSettings.stylePreset.value = PlayerStylePreset.classic;
            AppLayoutSettings.resetForTest();
          });

          await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(_label), findsOneWidget);
          final specRect = tester.getRect(find.text(_label));
          final sliderRect = tester.getRect(find.byType(Slider).first);
          if (inlineSpec) {
            // 海报模式：规格移到进度条上方，并在收藏与队列按钮之间居中。
            expect(
              specRect.bottom,
              lessThan(sliderRect.top),
              reason: '海报模式规格应位于进度条上方，实际 bottom=${specRect.bottom}',
            );
            final favoriteRect = tester.getRect(
              find.byKey(const ValueKey('player-favorite-button')),
            );
            final queueRect = tester.getRect(
              find.widgetWithIcon(IconButton, Icons.menu_rounded),
            );
            expect(specRect.center.dx, greaterThan(favoriteRect.right));
            expect(specRect.center.dx, lessThan(queueRect.left));
            expect(
              specRect.center.dx,
              closeTo((favoriteRect.right + queueRect.left) / 2, 2),
              reason: '规格应在收藏与队列按钮之间居中，实际 ${specRect.center.dx}',
            );
          } else {
            expect(specRect.top, greaterThan(sliderRect.bottom));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          await tester.pump();
        },
      );
    }
  }
}
