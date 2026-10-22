import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_island_lyric.dart';

void main() {
  setUp(() {
    IslandLyricSettings.resetForTest();
  });

  test('island lyric settings load, save, and default to disabled', () async {
    SharedPreferences.setMockInitialValues({
      'island_lyric_enabled': false,
    });

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.enabled.value, false);

    await IslandLyricSettings.setEnabled(true);
    expect(IslandLyricSettings.enabled.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_enabled'), true);
  });

  test('island lyric settings default show progress on', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.showProgress.value, true);

    await IslandLyricSettings.setShowProgress(false);
    expect(IslandLyricSettings.showProgress.value, false);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_show_progress'), false);
  });

  test('island lyric settings test mode defaults off and persists', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.testMode.value, false);

    await IslandLyricSettings.setTestMode(true);
    expect(IslandLyricSettings.testMode.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_test_mode'), true);
  });

  test('island lyric settings aod lyrics defaults off and persists', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(IslandLyricSettings.aodLyrics.value, false);

    await IslandLyricSettings.setAodLyrics(true);
    expect(IslandLyricSettings.aodLyrics.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_aod_lyrics'), true);
  });

  test('island lyric notification type defaults to live and persists', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(
      IslandLyricSettings.notificationType.value,
      IslandLyricSettings.typeLive,
      reason: '默认应走实时通知（无 root/Shizuku 路径）',
    );

    await IslandLyricSettings.setNotificationType(IslandLyricSettings.typeFocus);
    expect(
      IslandLyricSettings.notificationType.value,
      IslandLyricSettings.typeFocus,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('island_lyric_notification_type'),
      IslandLyricSettings.typeFocus,
    );
  });

  test('island lyric settings reset clears notification type', () async {
    SharedPreferences.setMockInitialValues({});
    await IslandLyricSettings.ensureLoaded();
    await IslandLyricSettings.setNotificationType(IslandLyricSettings.typeFocus);
    expect(
      IslandLyricSettings.notificationType.value,
      IslandLyricSettings.typeFocus,
    );

    IslandLyricSettings.resetForTest();
    expect(
      IslandLyricSettings.notificationType.value,
      IslandLyricSettings.typeLive,
      reason: 'reset 后应回到默认实时通知',
    );
  });

  test('island lyric bypass focus limit defaults off and persists', () async {
    SharedPreferences.setMockInitialValues({});

    await IslandLyricSettings.ensureLoaded();
    expect(
      IslandLyricSettings.bypassFocusLimit.value,
      false,
      reason: 'Shizuku 绕过白名单默认关闭',
    );

    await IslandLyricSettings.setBypassFocusLimit(true);
    expect(IslandLyricSettings.bypassFocusLimit.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('island_lyric_bypass_focus_limit'), true);
  });

  test('island lyric settings reset clears bypass focus limit', () async {
    SharedPreferences.setMockInitialValues({});
    await IslandLyricSettings.ensureLoaded();
    await IslandLyricSettings.setBypassFocusLimit(true);
    expect(IslandLyricSettings.bypassFocusLimit.value, true);

    IslandLyricSettings.resetForTest();
    expect(
      IslandLyricSettings.bypassFocusLimit.value,
      false,
      reason: 'reset 后应回到默认关闭绕过',
    );
  });
}
