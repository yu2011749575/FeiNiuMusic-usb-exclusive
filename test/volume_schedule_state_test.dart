import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_volume_schedule_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppVolumeScheduleSettings.periods.value = const [];
    AppVolumeScheduleSettings.enabled.value = false;
    AppVolumeScheduleSettings.manualVolume.value = 1;
    AppVolumeScheduleSettings.hasPersistedManualVolume = false;
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults are off with no periods', () async {
    SharedPreferences.setMockInitialValues({});

    await AppVolumeScheduleSettings.ensureLoaded();
    expect(AppVolumeScheduleSettings.enabled.value, false);
    expect(AppVolumeScheduleSettings.periods.value, isEmpty);
  });

  test('addPeriod persists and reloads', () async {
    SharedPreferences.setMockInitialValues({});
    await AppVolumeScheduleSettings.ensureLoaded();

    await AppVolumeScheduleSettings.addPeriod(
      startMin: 22 * 60,
      endMin: 8 * 60,
      volume: 0.3,
    );
    expect(AppVolumeScheduleSettings.periods.value.length, 1);
    final p = AppVolumeScheduleSettings.periods.value.first;
    expect(p.startMin, 22 * 60);
    expect(p.endMin, 8 * 60);
    expect(p.volume, 0.3);
    expect(p.id, isNotEmpty);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('volume_schedule_periods'), ['1320|480|0.30']);

    // 重新加载（模拟重启）→ 时间段恢复。
    await AppVolumeScheduleSettings.ensureLoaded();
    expect(AppVolumeScheduleSettings.periods.value.length, 1);
    expect(AppVolumeScheduleSettings.periods.value.first.startMin, 22 * 60);
    expect(AppVolumeScheduleSettings.periods.value.first.endMin, 8 * 60);
    expect(AppVolumeScheduleSettings.periods.value.first.volume, 0.3);
  });

  test('addPeriod clamps volume into [0,1]', () async {
    SharedPreferences.setMockInitialValues({});
    await AppVolumeScheduleSettings.ensureLoaded();

    await AppVolumeScheduleSettings.addPeriod(
      startMin: 600,
      endMin: 1200,
      volume: 1.7,
    );
    expect(AppVolumeScheduleSettings.periods.value.first.volume, 1);
  });

  test('updatePeriod modifies fields and removePeriod deletes', () async {
    SharedPreferences.setMockInitialValues({});
    await AppVolumeScheduleSettings.ensureLoaded();

    await AppVolumeScheduleSettings.addPeriod(
      startMin: 22 * 60,
      endMin: 8 * 60,
      volume: 0.3,
    );
    final id = AppVolumeScheduleSettings.periods.value.first.id;

    await AppVolumeScheduleSettings.updatePeriod(
      id,
      startMin: 21 * 60,
      volume: 0.5,
    );
    final updated = AppVolumeScheduleSettings.periods.value.first;
    expect(updated.startMin, 21 * 60);
    expect(updated.endMin, 8 * 60);
    expect(updated.volume, 0.5);
    expect(updated.id, id);

    await AppVolumeScheduleSettings.removePeriod(id);
    expect(AppVolumeScheduleSettings.periods.value, isEmpty);
  });

  test('setEnabled persists', () async {
    SharedPreferences.setMockInitialValues({});
    await AppVolumeScheduleSettings.ensureLoaded();

    await AppVolumeScheduleSettings.setEnabled(true);
    expect(AppVolumeScheduleSettings.enabled.value, true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('volume_schedule_enabled'), true);
  });

  group('activePeriodNow', () {
    DateTime at(int hour, int minute) => DateTime(2026, 8, 1, hour, minute);

    test('hits an overnight window and respects right-open end', () async {
      SharedPreferences.setMockInitialValues({});
      await AppVolumeScheduleSettings.ensureLoaded();
      await AppVolumeScheduleSettings.addPeriod(
        startMin: 22 * 60,
        endMin: 8 * 60,
        volume: 0.3,
      );

      expect(
        AppVolumeScheduleSettings.activePeriodNow(at(22, 30))?.volume,
        0.3,
      );
      expect(
        AppVolumeScheduleSettings.activePeriodNow(at(23, 59))?.volume,
        0.3,
      );
      expect(
        AppVolumeScheduleSettings.activePeriodNow(at(7, 59))?.volume,
        0.3,
      );
      // 08:00 是右开边界 → 不命中
      expect(AppVolumeScheduleSettings.activePeriodNow(at(8, 0)), isNull);
      expect(AppVolumeScheduleSettings.activePeriodNow(at(15, 0)), isNull);
    });

    test('hits a same-day window and respects boundaries', () async {
      SharedPreferences.setMockInitialValues({});
      await AppVolumeScheduleSettings.ensureLoaded();
      await AppVolumeScheduleSettings.addPeriod(
        startMin: 9 * 60,
        endMin: 12 * 60,
        volume: 0.7,
      );

      expect(
        AppVolumeScheduleSettings.activePeriodNow(at(9, 0))?.volume,
        0.7,
      );
      expect(
        AppVolumeScheduleSettings.activePeriodNow(at(11, 59))?.volume,
        0.7,
      );
      expect(AppVolumeScheduleSettings.activePeriodNow(at(12, 0)), isNull);
      expect(AppVolumeScheduleSettings.activePeriodNow(at(8, 59)), isNull);
    });

    test('with overlapping windows the first declared one wins', () async {
      SharedPreferences.setMockInitialValues({});
      await AppVolumeScheduleSettings.ensureLoaded();
      await AppVolumeScheduleSettings.addPeriod(
        startMin: 22 * 60,
        endMin: 8 * 60,
        volume: 0.3,
      );
      await AppVolumeScheduleSettings.addPeriod(
        startMin: 21 * 60,
        endMin: 23 * 60,
        volume: 0.5,
      );

      // 22:30 同时命中两个 → 取先声明的 0.3
      expect(
        AppVolumeScheduleSettings.activePeriodNow(at(22, 30))?.volume,
        0.3,
      );
      // 21:30 只命中第二个
      expect(
        AppVolumeScheduleSettings.activePeriodNow(at(21, 30))?.volume,
        0.5,
      );
    });
  });

  group('persistManualVolume', () {
    test('persists manual volume and reloads after restart', () async {
      SharedPreferences.setMockInitialValues({});
      await AppVolumeScheduleSettings.ensureLoaded();

      await AppVolumeScheduleSettings.persistManualVolume(0.8);
      expect(AppVolumeScheduleSettings.manualVolume.value, 0.8);
      expect(AppVolumeScheduleSettings.hasPersistedManualVolume, true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('volume_schedule_manual_volume'), 0.8);

      // 模拟重启：重新 ensureLoaded → 手动音量恢复。
      AppVolumeScheduleSettings.resetForTest();
      SharedPreferences.setMockInitialValues({
        'volume_schedule_manual_volume': 0.8,
      });
      await AppVolumeScheduleSettings.ensureLoaded();
      expect(AppVolumeScheduleSettings.manualVolume.value, 0.8);
      expect(AppVolumeScheduleSettings.hasPersistedManualVolume, true);
    });

    test('skips persisting while inside an active period', () async {
      SharedPreferences.setMockInitialValues({});
      await AppVolumeScheduleSettings.ensureLoaded();
      await AppVolumeScheduleSettings.addPeriod(
        startMin: 12 * 60,
        endMin: 13 * 60,
        volume: 0.3,
      );
      await AppVolumeScheduleSettings.setEnabled(true);

      // 12:30 处于生效时段：此时音量是段内强制值 0.3，绝不能被记为手动音量。
      await AppVolumeScheduleSettings.persistManualVolume(
        0.3,
        now: DateTime(2026, 8, 1, 12, 30),
      );
      expect(AppVolumeScheduleSettings.manualVolume.value, 1);
      expect(AppVolumeScheduleSettings.hasPersistedManualVolume, false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('volume_schedule_manual_volume'), isNull);

      // 时段外手动调音量 → 正常持久化。
      await AppVolumeScheduleSettings.persistManualVolume(
        0.8,
        now: DateTime(2026, 8, 1, 16, 30),
      );
      expect(AppVolumeScheduleSettings.manualVolume.value, 0.8);
      expect(AppVolumeScheduleSettings.hasPersistedManualVolume, true);
    });
  });
}
