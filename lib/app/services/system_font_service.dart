import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads the font families installed on the current desktop operating system.
///
/// Flutter deliberately does not expose a cross-platform font enumeration API,
/// so each desktop runner implements this channel with its native font manager.
class SystemFontService {
  static const _channel = MethodChannel('com.feiniu.music/system_fonts');

  static Future<List<String>>? _loading;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static Future<List<String>> availableFamilies() {
    if (!supported) return Future.value(const []);
    return _loading ??= _load();
  }

  static Future<List<String>> _load() async {
    try {
      final result = await _channel.invokeListMethod<String>('getFamilies');
      final families =
          (result ?? const <String>[])
              .map((family) => family.trim())
              .where((family) => family.isNotEmpty)
              .toSet()
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return families;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Unable to enumerate system fonts: $error');
      }
      return const [];
    }
  }

  @visibleForTesting
  static void resetForTest() => _loading = null;
}
