import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DebugLogService {
  DebugLogService._();

  static final DebugLogService instance = DebugLogService._();

  static const String _prefsEnabled = 'debug_log_enabled';
  static const String _prefsLogs = 'debug_log_entries';
  static const int _maxEntries = 300;

  final ValueNotifier<bool> enabled = ValueNotifier(false);
  final ValueNotifier<List<String>> entries = ValueNotifier(<String>[]);

  DebugPrintCallback? _originalDebugPrint;
  Future<void>? _loading;
  bool _installed = false;
  bool _persistScheduled = false;

  Future<void> ensureLoaded() => _loading ??= _doLoad();

  /// 测试专用：重置内存状态并还原被覆盖的全局 [debugPrint]，避免测试间
  /// hook 链式叠加或残留 enable 状态。
  @visibleForTesting
  void resetForTest() {
    _loading = null;
    _persistScheduled = false;
    if (_installed && _originalDebugPrint != null) {
      debugPrint = _originalDebugPrint!;
    }
    _installed = false;
    _originalDebugPrint = null;
    enabled.value = false;
    entries.value = <String>[];
  }

  Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    entries.value = prefs.getStringList(_prefsLogs) ?? <String>[];
    _installDebugPrintHook();
  }

  Future<void> setEnabled(bool value) async {
    await ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
    if (value) {
      add('调试日志已开启');
    }
  }

  Future<void> clear() async {
    await ensureLoaded();
    entries.value = <String>[];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsLogs);
  }

  String exportText() {
    if (entries.value.isEmpty) return 'No debug logs.';
    return entries.value.reversed.join('\n');
  }

  void add(String message) {
    if (!enabled.value) return;
    final now = DateTime.now();
    final time =
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    final next = <String>['[$time] $message', ...entries.value];
    if (next.length > _maxEntries) {
      next.removeRange(_maxEntries, next.length);
    }
    entries.value = next;
    _schedulePersist();
  }

  void _installDebugPrintHook() {
    if (_installed) return;
    _installed = true;
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        add(message);
      }
      _originalDebugPrint?.call(message, wrapWidth: wrapWidth);
    };
  }

  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      _persistScheduled = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsLogs, entries.value);
    });
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}
