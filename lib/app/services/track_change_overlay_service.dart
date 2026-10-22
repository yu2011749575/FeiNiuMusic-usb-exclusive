import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show Brightness, Color, ColorScheme, ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../state/settings_layout_state.dart';
import '../state/settings_theme_state.dart' show AppThemeSettings;
import '../state/song_state.dart';
import 'cover_local_cache.dart';
import 'player_service.dart';

/// 切歌通知·悬浮窗服务（单一渲染器）。
///
/// 悬浮窗是切歌通知的唯一实现：前台悬浮窗盖在应用上（原应用内弹窗效果），
/// 后台盖在系统上。监听 currentSong，「真实切歌」判定 + 前后台判定后经
/// MethodChannel 驱动原生 OverlayTrackChange。
class TrackChangeOverlayService {
  TrackChangeOverlayService._();

  static final TrackChangeOverlayService instance = TrackChangeOverlayService._();

  static const MethodChannel _channel = MethodChannel(
    'com.feiniu.music/track_change_overlay',
  );

  /// 前后台生命周期观察者。以私有静态实例持有并注册到 [WidgetsBinding]，
  /// 避免在以静态成员为主的类上直接混入 [WidgetsBindingObserver]。
  static final _LifecycleObserver _lifecycleObserver = _LifecycleObserver();

  static bool _started = false;
  static ValueListenable<SongEntity?>? _currentSong;
  static String? _lastTrackId;
  static bool _appForeground = true;
  static bool _showing = false;

  /// 悬浮窗权限提示标记：每会话只提示一次，避免每次切歌都打扰。
  static bool _permissionHintShown = false;

  /// 幂等启动。默认监听 [PlayerService.instance.currentSong]；测试可注入。
  static void start({ValueListenable<SongEntity?>? currentSong}) {
    if (_started) return;
    _started = true;
    final listenable = currentSong ?? PlayerService.instance.currentSong;
    _currentSong = listenable;
    _lastTrackId = listenable.value?.id;
    listenable.addListener(_onCurrentSongChanged);
    AppLayoutSettings.trackChangeNotify.addListener(_onSettingsChanged);
    AppLayoutSettings.trackChangeOverlayNotify.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
  }

  @visibleForTesting
  static void resetForTest() {
    if (!_started) return;
    _currentSong?.removeListener(_onCurrentSongChanged);
    _currentSong = null;
    AppLayoutSettings.trackChangeNotify.removeListener(_onSettingsChanged);
    AppLayoutSettings.trackChangeOverlayNotify.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _started = false;
    _lastTrackId = null;
    _appForeground = true;
    _showing = false;
    _permissionHintShown = false;
    _channel.invokeMethod('hide');
  }

  @visibleForTesting
  static bool shouldShow({
    required bool notifyEnabled,
    required bool overlayEnabled,
    required bool appForeground,
    required String? previousId,
    required String newId,
  }) {
    if (!notifyEnabled) return false;
    if (previousId == null) return false;
    if (previousId == newId) return false;
    if (!appForeground && !overlayEnabled) return false;
    return true;
  }

  @visibleForTesting
  static Map<String, Object?> buildPayload({
    required String title,
    required String artist,
    required int durationMs,
    required bool isLarge,
    required double scale,
    String? coverPath,
    required bool isDark,
    required int cardColor,
    required int textColor,
    required int secondaryColor,
    required int accentColor,
  }) {
    return {
      'title': title,
      'artist': artist,
      'durationMs': durationMs,
      'isLarge': isLarge,
      'scale': scale,
      'coverPath': coverPath,
      'isDark': isDark,
      'cardColor': cardColor,
      'textColor': textColor,
      'secondaryColor': secondaryColor,
      'accentColor': accentColor,
    };
  }

  /// 悬浮窗卡片在两种主题下的配色（与 app 主题联动）。
  ///
  /// - [isDark]：深色模式（卡片深底 / 白字）。
  /// - [card]：卡片背景色。
  /// - [text]：主文字色（歌名）。
  /// - [secondary]：次级文字色（歌手 / 关闭按钮）。
  /// - [accent]：强调色（「正在播放」标题 / 音浪条）。
  @visibleForTesting
  static TrackChangeOverlayCardColors computeCardColors() {
    final themeMode = AppThemeSettings.themeMode.value;
    final platformBrightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final isDark = switch (themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformBrightness == Brightness.dark,
    };
    final seed = AppThemeSettings.themeSeedColor.value ?? const Color(0xFF3B82F6);
    final accent =
        AppThemeSettings.dynamicColorEnabled.value
            ? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light)
                .primary
            : seed;
    if (isDark) {
      return (
        isDark: true,
        card: const Color(0xFF262A30),
        text: const Color(0xFFFFFFFF),
        secondary: const Color(0xFFB0B3B8),
        accent: accent,
      );
    }
    return (
      isDark: false,
      card: const Color(0xFFFFFFFF),
      text: const Color(0xFF1A1A1A),
      secondary: const Color(0xFF6B7280),
      accent: accent,
    );
  }

  static Future<bool> hasOverlayPermission() async {
    try {
      final ok = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openOverlaySettings() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openOverlaySettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static void _onCurrentSongChanged() {
    final listenable = _currentSong;
    if (listenable == null) return;
    final song = listenable.value;
    final newId = song?.id;
    if (newId == null) {
      _lastTrackId = null;
      _hide();
      return;
    }
    final previousId = _lastTrackId;
    _lastTrackId = newId;

    if (!shouldShow(
      notifyEnabled: AppLayoutSettings.trackChangeNotify.value,
      overlayEnabled: AppLayoutSettings.trackChangeOverlayNotify.value,
      appForeground: _appForeground,
      previousId: previousId,
      newId: newId,
    )) {
      return;
    }

    _show(song!);
  }

  static void _onSettingsChanged() {
    final shouldHide = !AppLayoutSettings.trackChangeNotify.value ||
        (!_appForeground && !AppLayoutSettings.trackChangeOverlayNotify.value);
    if (shouldHide) _hide();
  }

  static Future<void> _show(SongEntity song) async {
    // 打开切歌弹窗前校验悬浮窗权限：缺失时每会话用原生 Toast 引导一次，
    // 而非静默失败；权限就绪后重置提示标记。
    if (!await hasOverlayPermission()) {
      if (!_permissionHintShown) {
        _permissionHintShown = true;
        _channel.invokeMethod('showPermissionToast');
      }
      return;
    }
    _permissionHintShown = false;

    final durationMs = AppLayoutSettings.trackChangeToastDurationMs.value
        .clamp(2000, 10000);
    final isLarge =
        AppLayoutSettings.tvMode.value || AppLayoutSettings.tabletMode.value;
    final scale = isLarge
        ? AppLayoutSettings.trackChangeToastScale.value.clamp(1.0, 3.0)
        : 1.0;

    _showing = true;
    final colors = computeCardColors();
    _channel.invokeMethod('show', buildPayload(
      title: song.title,
      artist: song.artistDisplayName,
      durationMs: durationMs,
      isLarge: isLarge,
      scale: scale,
      coverPath: null,
      isDark: colors.isDark,
      cardColor: colors.card.toARGB32(),
      textColor: colors.text.toARGB32(),
      secondaryColor: colors.secondary.toARGB32(),
      accentColor: colors.accent.toARGB32(),
    ));
    _downloadCover(song);
  }

  static Future<void> _downloadCover(SongEntity song) async {
    final coverId = song.coverId;
    if (coverId == null || coverId.isEmpty) return;
    final path = await CoverLocalCache.downloadToLocal(
      coverId,
      updatedAt: song.updatedAt,
    );
    if (path == null) return;
    // 封面就绪后补发 updateCover（带 coverPath），原生层就地刷新封面：
    // 不重建窗口、不重置 dismiss 计时器（避免卡片消失后又冒出来 / 快速封面闪烁）。
    // 仅当当前仍是这首歌且悬浮窗仍处于显示状态时补发。
    if (_lastTrackId == song.id && _showing) {
      _channel.invokeMethod('updateCover', {'coverPath': path});
    }
  }

  static void _hide() {
    _showing = false;
    _channel.invokeMethod('hide');
  }
}

/// 前后台状态观察者：切到后台且未开「后台悬浮窗」子开关时隐藏悬浮窗。
class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    TrackChangeOverlayService._appForeground =
        state == AppLifecycleState.resumed;
    if (!TrackChangeOverlayService._appForeground &&
        !AppLayoutSettings.trackChangeOverlayNotify.value) {
      TrackChangeOverlayService._hide();
    }
  }
}

/// 悬浮窗卡片配色（由 [TrackChangeOverlayService.computeCardColors] 产出，
/// 原生层按这些 ARGB 值渲染，不再硬编码颜色）。
@visibleForTesting
typedef TrackChangeOverlayCardColors =
    ({
      bool isDark,
      Color card,
      Color text,
      Color secondary,
      Color accent,
    });
