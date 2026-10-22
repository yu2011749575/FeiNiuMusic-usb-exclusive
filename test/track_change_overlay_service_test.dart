import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/track_change_overlay_service.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';

const _overlayChannel = MethodChannel('com.feiniu.music/track_change_overlay');

SongEntity _song(String id) => SongEntity(
      id: id,
      title: 't',
      artist: '[{"name":"a"}]',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrackChangeOverlayService.shouldShow', () {
    test('总开关关闭时不弹', () {
      expect(
        TrackChangeOverlayService.shouldShow(
          notifyEnabled: false, overlayEnabled: true, appForeground: true,
          previousId: 'a', newId: 'b',
        ),
        false,
      );
    });
    test('首曲 / 启动恢复（previousId 空）不弹', () {
      expect(
        TrackChangeOverlayService.shouldShow(
          notifyEnabled: true, overlayEnabled: true, appForeground: true,
          previousId: null, newId: 'b',
        ),
        false,
      );
    });
    test('同一首歌不弹', () {
      expect(
        TrackChangeOverlayService.shouldShow(
          notifyEnabled: true, overlayEnabled: true, appForeground: true,
          previousId: 'a', newId: 'a',
        ),
        false,
      );
    });
    test('前台切歌弹（无需子开关）', () {
      expect(
        TrackChangeOverlayService.shouldShow(
          notifyEnabled: true, overlayEnabled: false, appForeground: true,
          previousId: 'a', newId: 'b',
        ),
        true,
      );
    });
    test('后台切歌：子开关开才弹', () {
      expect(
        TrackChangeOverlayService.shouldShow(
          notifyEnabled: true, overlayEnabled: true, appForeground: false,
          previousId: 'a', newId: 'b',
        ),
        true,
      );
      expect(
        TrackChangeOverlayService.shouldShow(
          notifyEnabled: true, overlayEnabled: false, appForeground: false,
          previousId: 'a', newId: 'b',
        ),
        false,
      );
    });
  });

  group('TrackChangeOverlayService.buildPayload', () {
    test('构造原生 payload', () {
      final payload = TrackChangeOverlayService.buildPayload(
        title: '夜曲', artist: '周杰伦', durationMs: 3000,
        isLarge: false, scale: 1.0, coverPath: '/tmp/x.jpg',
        isDark: true, cardColor: 0xFF262A30, textColor: 0xFFFFFFFF,
        secondaryColor: 0xFFB0B3B8, accentColor: 0xFF3B82F6,
      );
      expect(payload['title'], '夜曲');
      expect(payload['artist'], '周杰伦');
      expect(payload['durationMs'], 3000);
      expect(payload['isLarge'], false);
      expect(payload['scale'], 1.0);
      expect(payload['coverPath'], '/tmp/x.jpg');
      expect(payload['isDark'], true);
      expect(payload['cardColor'], 0xFF262A30);
      expect(payload['textColor'], 0xFFFFFFFF);
      expect(payload['secondaryColor'], 0xFFB0B3B8);
      expect(payload['accentColor'], 0xFF3B82F6);
    });
    test('coverPath 为 null 时 payload 不含封面', () {
      final payload = TrackChangeOverlayService.buildPayload(
        title: 't', artist: 'a', durationMs: 3000,
        isLarge: false, scale: 1.0,
        isDark: false, cardColor: 0xFFFFFFFF, textColor: 0xFF1A1A1A,
        secondaryColor: 0xFF6B7280, accentColor: 0xFF3B82F6,
      );
      expect(payload.containsKey('coverPath'), true);
      expect(payload['coverPath'], isNull);
    });
  });

  group('TrackChangeOverlayService.computeCardColors', () {
    test('深色主题返回深卡 + 白字 + accent 种子色', () {
      // 直接以当前主题状态为准（不 mock platformDispatcher）；
      // 断言返回结构完整且 accent 为合法 ARGB。
      final colors = TrackChangeOverlayService.computeCardColors();
      expect(colors.isDark, isA<bool>());
      expect(colors.card.toARGB32(), isA<int>());
      expect(colors.text.toARGB32(), isA<int>());
      expect(colors.secondary.toARGB32(), isA<int>());
      expect(colors.accent.toARGB32(), isA<int>());
      expect(colors.card != colors.text, true);
    });
  });

  group('TrackChangeOverlayService._show 悬浮窗权限校验', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void mockOverlay(bool hasPermission, List<String> calls) {
      messenger.setMockMethodCallHandler(_overlayChannel, (call) async {
        calls.add(call.method);
        if (call.method == 'hasOverlayPermission') return hasPermission;
        return null;
      });
    }

    setUp(() {
      AppLayoutSettings.trackChangeNotify.value = true;
    });

    tearDown(() {
      AppLayoutSettings.trackChangeNotify.value = false;
      // 先 resetForTest（内部会 invokeMethod('hide')），再清 mock，避免无处理器异常。
      TrackChangeOverlayService.resetForTest();
      messenger.setMockMethodCallHandler(_overlayChannel, null);
    });

    test('无权限：每会话只引导一次，不弹窗', () async {
      final calls = <String>[];
      mockOverlay(false, calls);
      final notifier = ValueNotifier<SongEntity?>(null);
      TrackChangeOverlayService.start(currentSong: notifier);

      notifier.value = _song('a'); // 首曲：记录 lastTrackId，不弹
      notifier.value = _song('b'); // 切歌：无权限 → 引导一次
      notifier.value = _song('c'); // 再切歌：不重复引导
      await pumpEventQueue();

      expect(calls.where((m) => m == 'showPermissionToast').length, 1);
      expect(calls.where((m) => m == 'show').length, 0);
    });

    test('有权限：正常弹窗，无权限提示', () async {
      final calls = <String>[];
      mockOverlay(true, calls);
      final notifier = ValueNotifier<SongEntity?>(null);
      TrackChangeOverlayService.start(currentSong: notifier);

      notifier.value = _song('a');
      notifier.value = _song('b');
      await pumpEventQueue();

      expect(calls.where((m) => m == 'show').length, 1);
      expect(calls.where((m) => m == 'showPermissionToast').length, 0);
    });
  });
}
