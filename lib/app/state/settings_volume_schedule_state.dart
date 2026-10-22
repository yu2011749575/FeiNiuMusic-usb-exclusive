import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个每天重复的定时音量时间段。
///
/// [startMin]/[endMin] 为距午夜分钟数（0-1439）。
/// 当 [endMin] < [startMin] 时表示跨午夜（如 22:00 -> 08:00）。
class VolumeSchedulePeriod {
  final String id;
  final int startMin;
  final int endMin;
  final double volume;

  const VolumeSchedulePeriod({
    required this.id,
    required this.startMin,
    required this.endMin,
    required this.volume,
  });

  VolumeSchedulePeriod copyWith({
    String? id,
    int? startMin,
    int? endMin,
    double? volume,
  }) {
    return VolumeSchedulePeriod(
      id: id ?? this.id,
      startMin: startMin ?? this.startMin,
      endMin: endMin ?? this.endMin,
      volume: volume ?? this.volume,
    );
  }
}

/// 定时音量设置：在指定时间段内自动按设定音量输出，区间外恢复手动音量。
///
/// 模式参照 [settings_playback_state.dart] 中 AppPlaybackVolumeSettings：
/// `static const _prefsX` / `static final ValueNotifier` / `_loading` /
/// `ensureLoaded()=>_loading??=_doLoad()` / setter clamp+persist+notifier。
class AppVolumeScheduleSettings {
  static const String _prefsEnabled = 'volume_schedule_enabled';
  static const String _prefsPeriods = 'volume_schedule_periods';
  static const String _prefsManualVolume = 'volume_schedule_manual_volume';

  /// 定时音量总开关。
  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  /// 已配置的时间段列表。
  static final ValueNotifier<List<VolumeSchedulePeriod>> periods = ValueNotifier(
    const [],
  );

  /// 手动音量：离开时间段时恢复的目标音量。
  ///
  /// 在用户手动调节音量（且不在生效时段内）及首次进入时间段时记录并持久化。
  /// 持久化保证「时段内 App 被关闭 → 重启/再打开后仍能恢复正确的手动音量」，
  /// 而不是把上个时段遗留的段内强制音量误当成手动音量。
  static final ValueNotifier<double> manualVolume = ValueNotifier(1);

  /// 是否已持久化过手动音量（区分首次使用与已记录，见 [persistManualVolume]）。
  static bool hasPersistedManualVolume = false;

  /// 当前时刻是否正命中某个时间段（供 UI 展示生效指示）。
  static final ValueNotifier<bool> isActiveNow = ValueNotifier(false);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    periods.value = _decodePeriods(prefs.getStringList(_prefsPeriods));
    final stored = prefs.getDouble(_prefsManualVolume);
    if (stored != null) {
      manualVolume.value = stored.clamp(0, 1).toDouble();
      hasPersistedManualVolume = true;
    }
  }

  /// 记录并持久化手动音量（离开时间段时恢复的目标）。
  ///
  /// 只在用户手动调节音量且当前未处于生效时段内时调用。跨场景防抖：
  /// - 时段内 App 重启：`manualVolume` 仍是上次持久化的手动值（persist 被跳过）；
  /// - 重启后首次恢复：手动值已从 prefs 加载，直接恢复，不覆盖成遗留的段内值；
  /// - 开关/时段变更触发的一次性校验：persist 跳过。
  ///
  /// [now] 仅在测试中注入固定时间，生产走 `DateTime.now()`。
  static Future<void> persistManualVolume(
    double value, {
    DateTime? now,
  }) async {
    if (AppVolumeScheduleSettings.enabled.value &&
        activePeriodNow(now ?? DateTime.now()) != null) {
      // 生效时段内：任何进入/离开或音量变化都会重复触发此方法，
      // 但此时音量可能处于段内强制值，绝不能当成手动音量持久化。
      return;
    }
    if (hasPersistedManualVolume &&
        (manualVolume.value - value).abs() < 0.001) {
      // 已持久化过且值未变：避免反复写 prefs（开关/时段变更会触发）。
      return;
    }
    manualVolume.value = value.clamp(0, 1).toDouble();
    hasPersistedManualVolume = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _prefsManualVolume,
      manualVolume.value,
    );
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }

  static Future<void> addPeriod({
    required int startMin,
    required int endMin,
    required double volume,
  }) async {
    final id = _newId();
    final next = List<VolumeSchedulePeriod>.from(periods.value)
      ..add(
        VolumeSchedulePeriod(
          id: id,
          startMin: startMin,
          endMin: endMin,
          volume: volume.clamp(0, 1).toDouble(),
        ),
      );
    await _persistPeriods(next);
  }

  static Future<void> updatePeriod(
    String id, {
    int? startMin,
    int? endMin,
    double? volume,
  }) async {
    final next = periods.value
        .map((p) => p.id == id
            ? p.copyWith(
                startMin: startMin,
                endMin: endMin,
                volume: volume,
              )
            : p)
        .toList();
    await _persistPeriods(next);
  }

  static Future<void> removePeriod(String id) async {
    final next = periods.value.where((p) => p.id != id).toList();
    await _persistPeriods(next);
  }

  static Future<void> _persistPeriods(List<VolumeSchedulePeriod> next) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsPeriods, _encodePeriods(next));
    periods.value = next;
  }

  /// 返回当前时间命中的时间段；无命中返回 null。
  ///
  /// 跨午夜时间段（startMin > endMin）命中条件：`m >= start || m < end`。
  /// 边界为右开（m < endMin），避免相邻时间段重叠。
  static VolumeSchedulePeriod? activePeriodNow(DateTime now) {
    final m = now.hour * 60 + now.minute;
    for (final p in periods.value) {
      final hit = p.startMin <= p.endMin
          ? (m >= p.startMin && m < p.endMin)
          : (m >= p.startMin || m < p.endMin);
      if (hit) return p;
    }
    return null;
  }

  // ---------- 序列化 ----------

  static List<String> _encodePeriods(List<VolumeSchedulePeriod> list) {
    return list
        .map((p) => '${p.startMin}|${p.endMin}|${p.volume.toStringAsFixed(2)}')
        .toList();
  }

  static List<VolumeSchedulePeriod> _decodePeriods(List<String>? raw) {
    if (raw == null) return const [];
    final result = <VolumeSchedulePeriod>[];
    for (final item in raw) {
      final parts = item.split('|');
      if (parts.length != 3) continue;
      final start = int.tryParse(parts[0]);
      final end = int.tryParse(parts[1]);
      final vol = double.tryParse(parts[2]);
      if (start == null || end == null || vol == null) continue;
      if (start < 0 || start > 1439 || end < 0 || end > 1439) continue;
      result.add(
        VolumeSchedulePeriod(
          id: _newId(),
          startMin: start,
          endMin: end,
          volume: vol.clamp(0, 1).toDouble(),
        ),
      );
    }
    return result;
  }

  static String _newId() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch}${r.nextInt(0xFFFF).toRadixString(16)}';
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试模拟重启复用。
  static void resetForTest() {
    _loading = null;
  }
}
