import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_playback_state.dart';
import 'package:feiniu_music/app/state/settings_volume_schedule_state.dart';
import 'package:feiniu_music/app/services/volume_schedule_service.dart';

/// 回归测试：定时音量在生效时段内不应覆盖手动调节的音量。
///
/// 历史 bug：1 秒心跳 _applySchedule() 在生效时段内检测到
/// volume.value != p.volume 就强制写回段内音量，导致用户手动拖音量
/// 约 1 秒内被拉回定时值。修复后：仅进入/离开时段、开关/设置变更时
/// 应用一次，生效时段内手动调节不再被心跳强拉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 时间段锚定到真实当前时间：让注入的 now 与 AppPlaybackVolumeSettings.setVolume
  // 内部 persistManualVolume 使用的真实 DateTime.now() 都落在同一时段内，
  // 避免「段内强制值被 guard 放过、误记成手动音量」——生产里真实时钟自洽，
  // 测试里必须让两个时钟一致才能还原生产行为。
  late VolumeSchedulePeriod _period;
  late DateTime _nowIn; // 时段内
  late DateTime _nowLaterIn; // 时段内（+1 分钟）
  late DateTime _nowOutside; // 时段外（+2 小时）

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppVolumeScheduleSettings.resetForTest();
    AppPlaybackVolumeSettings.volume.value = 1;
    AppVolumeScheduleSettings.periods.value = const [];
    AppVolumeScheduleSettings.enabled.value = false;
    AppVolumeScheduleSettings.manualVolume.value = 1;
    AppVolumeScheduleSettings.hasPersistedManualVolume = false;
    VolumeScheduleService.instance.dispose();

    final nowMin = DateTime.now().hour * 60 + DateTime.now().minute;
    _period = VolumeSchedulePeriod(
      id: 'test-p',
      startMin: (nowMin - 30) % 1440,
      endMin: (nowMin + 30) % 1440,
      volume: 0.3,
    );
    _nowIn = DateTime.now();
    _nowLaterIn = _nowIn.add(const Duration(minutes: 1));
    _nowOutside = _nowIn.add(const Duration(hours: 2));
  });

  Future<void> loadWith({
    required bool enabled,
    required List<VolumeSchedulePeriod> periods,
    double? manualVolume,
  }) async {
    AppVolumeScheduleSettings.resetForTest();
    await AppVolumeScheduleSettings.ensureLoaded();
    AppVolumeScheduleSettings.enabled.value = enabled;
    AppVolumeScheduleSettings.periods.value = periods;
    // 手动音量恢复目标直接设置（持久化路径已由 volume_schedule_state_test 覆盖）。
    if (manualVolume != null) {
      AppVolumeScheduleSettings.manualVolume.value = manualVolume;
      AppVolumeScheduleSettings.hasPersistedManualVolume = true;
    }
    AppPlaybackVolumeSettings.volume.value = manualVolume ?? 1;
  }

  VolumeSchedulePeriod period({
    required int startMin,
    required int endMin,
    required double volume,
  }) {
    return VolumeSchedulePeriod(
      id: 'test-p',
      startMin: startMin,
      endMin: endMin,
      volume: volume,
    );
  }

  group('VolumeScheduleService 生效时段内', () {
    test('手动调节音量不再被心跳强制覆盖', () async {
      await loadWith(
        enabled: true,
        periods: [_period],
        manualVolume: 0.8,
      );

      // 时段内 → 进入时段应应用段内音量 0.3
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.3);

      // 用户在生效时段内手动把音量调到 0.9
      await AppPlaybackVolumeSettings.setVolume(0.9);
      expect(AppPlaybackVolumeSettings.volume.value, 0.9);

      // 心跳 tick（同时间段、同设置）→ 不应把音量拉回 0.3
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowLaterIn);
      expect(
        AppPlaybackVolumeSettings.volume.value,
        0.9,
        reason: '生效时段内手动调节的音量不应被心跳覆盖',
      );
    });

    test('离开时间段后恢复手动音量（原有行为保持）', () async {
      await loadWith(
        enabled: true,
        periods: [_period],
        manualVolume: 0.8,
      );

      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.3);

      // 离开时段 → 恢复手动音量 0.8
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowOutside);
      expect(AppPlaybackVolumeSettings.volume.value, 0.8);
    });

    test('进入新时间段时应用段内音量（原有行为保持）', () async {
      await loadWith(
        enabled: true,
        periods: [_period],
        manualVolume: 0.8,
      );

      // 进入时段 → 应用段内音量 0.3
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.3);
    });

    test('时间段内手动调节后，同一时段内再次应用不应重置音量', () async {
      await loadWith(
        enabled: true,
        periods: [_period],
        manualVolume: 0.8,
      );

      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.3);

      // 用户手动调到 0.5
      await AppPlaybackVolumeSettings.setVolume(0.5);
      expect(AppPlaybackVolumeSettings.volume.value, 0.5);

      // 再次 applySchedule（同一时段）→ 仍应保留用户手动值
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowLaterIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.5);
    });

    test('设置变更（编辑生效时段音量）立即应用段内音量', () async {
      // 本用例需要触发 _onSettingsChanged（periods listener），单独注册并在结尾清理。
      VolumeScheduleService.instance.registerListenersForTest();
      addTearDown(VolumeScheduleService.instance.dispose);

      await loadWith(
        enabled: true,
        periods: [_period],
        manualVolume: 0.8,
      );

      // 进入时段 → 应用段内音量 0.3
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.3);

      // 用户在生效时段内手动调到 0.6
      await AppPlaybackVolumeSettings.setVolume(0.6);

      // 设置变更（编辑时段音量 0.3 → 0.5）→ forceApply 应立即应用新段内音量。
      AppVolumeScheduleSettings.periods.value = [
        _period.copyWith(volume: 0.5),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(AppPlaybackVolumeSettings.volume.value, 0.5);
    });
  });

  group('VolumeScheduleService 开关关闭时', () {
    test('关闭开关且处于生效时段 → 恢复手动音量', () async {
      await loadWith(
        enabled: true,
        periods: [_period],
        manualVolume: 0.8,
      );
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.3);

      // 关闭开关
      AppVolumeScheduleSettings.enabled.value = false;
      await VolumeScheduleService.instance.applyScheduleForTest(now: _nowIn);
      expect(AppPlaybackVolumeSettings.volume.value, 0.8);
    });
  });
}
