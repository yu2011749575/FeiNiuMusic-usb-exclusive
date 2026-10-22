import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/state/settings_desktop_lyrics_state.dart';

const _desktopLyricsChannelName = 'com.feiniu.music/desktop_lyrics_window';
const _desktopLyricsChannel = WindowMethodChannel(
  _desktopLyricsChannelName,
  mode: ChannelMode.bidirectional,
);

/// 桌面歌词窗口的原生通道（仅 macOS 注册）。
const _desktopLyricsNativeChannel = MethodChannel(
  'com.feiniu.music/desktop_lyrics_window/native',
);

/// 第二窗口没有 Material/Scaffold 祖先，MaterialApp 会把自带的兜底文字样式
/// （黄色双下划线 + monospace）当作 DefaultTextStyle。显式给一份干净的基础
/// 样式，否则歌词会带下划线；字号/字体留空时也不会被兜底成 monospace。
const _baseTextStyle = TextStyle(
  color: Colors.white,
  fontSize: 24,
  fontWeight: FontWeight.w600,
  decoration: TextDecoration.none,
);

/// 显示歌词窗口。
///
/// macOS 上 window_manager.show() 内部是 makeKeyAndOrderFront +
/// NSApp.activate(ignoringOtherApps:)，而歌词状态每次播放进度更新都会触发一次
/// 显示，会把主窗口的键盘焦点反复抢走（输入框无法获得/保持焦点）。
/// 原生通道用 orderFrontRegardless() 只把窗口提到最前，不激活应用、不抢 key。
/// Windows/Linux 没有该通道，退化为「仅在窗口隐藏时显示一次」，避免
/// window_manager.show()（Windows 会 SetForegroundWindow）被反复调用。
Future<void> _showWindow() async {
  if (Platform.isMacOS) {
    try {
      await _desktopLyricsNativeChannel
          .invokeMethod<void>('showPassive')
          .timeout(const Duration(milliseconds: 500));
      return;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('desktop lyrics passive show failed, fallback: $error');
      }
    }
  }
  if (await windowManager.isVisible()) return;
  await windowManager.show();
}

/// 只有「自由拖动」模式需要接收鼠标事件。固定和锁定模式均点击穿透，
/// 避免常驻在最前的歌词条遮住下层输入框或按钮。
Future<void> _applyClickThrough(String? position) async {
  final ignore = position != DesktopLyricsSettings.positionFree;
  await windowManager.setIgnoreMouseEvents(ignore, forward: ignore);
}

/// 第二个 Flutter 引擎中的桌面歌词窗口。
Future<void> runDesktopLyricsWindow(WindowController controller) async {
  await windowManager.ensureInitialized();
  const windowSize = Size(760, 112);
  final windowOptions = WindowOptions(
    size: windowSize,
    minimumSize: windowSize,
    maximumSize: windowSize,
    center: true,
    alwaysOnTop: true,
    // macOS 上 window_manager 把 skipTaskbar 实现为
    // NSApplication.setActivationPolicy(.accessory)，是进程级设置：歌词窗口
    // 一创建，整个应用的 Dock 图标与激活策略就被改掉且不会恢复。Windows/Linux
    // 是窗口级样式（工具窗口 / 跳过任务栏），只在非 macOS 保留。
    skipTaskbar: !Platform.isMacOS,
    backgroundColor: Colors.transparent,
    title: '飞牛音乐桌面歌词',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setHasShadow(false);
    // setAsFrameless() 在 macOS window_manager 0.5.x 会把 isOpaque 设回 true，
    // 导致背景透明度看起来始终不生效。隐藏标题栏已足够无边框，这里显式保留透明窗口。
    await windowManager.setBackgroundColor(Colors.transparent);
    await _applyClickThrough(DesktopLyricsSettings.positionFixed);
    await _showWindow();
  });

  final state = DesktopLyricsWindowState();
  String? lastPosition;
  const channel = _desktopLyricsChannel;
  await channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'setState':
        if (call.arguments is Map) {
          state.update(Map<String, Object?>.from(call.arguments as Map));
        }
        return null;
      case 'show':
        await _showWindow();
        await _applyClickThrough(
          lastPosition ?? DesktopLyricsSettings.positionFixed,
        );
        return null;
      case 'hide':
        await windowManager.hide();
        return null;
      case 'position':
        final arguments = call.arguments;
        final position = arguments is Map
            ? arguments['mode'] as String?
            : arguments as String?;
        final locked = position == DesktopLyricsSettings.positionLocked;
        if (position != lastPosition || locked) {
          lastPosition = position;
          await _applyClickThrough(position);
          if (locked && arguments is Map) {
            final x = (arguments['x'] as num?)?.toDouble();
            final y = (arguments['y'] as num?)?.toDouble();
            if (x != null && y != null) {
              await windowManager.setPosition(Offset(x, y));
            }
          } else if (!locked) {
            await _applyPosition(position);
          }
        }
        return null;
      default:
        throw MissingPluginException('Unknown desktop lyrics method');
    }
  });

  // Parent window registers its handler before creating this window. The
  // handshake lets it flush the latest song/style payload after startup.
  unawaited(channel.invokeMethod<void>('ready'));
  runApp(DesktopLyricsWindow(state: state));
}

Future<void> _applyPosition(String? value) async {
  if (value == DesktopLyricsSettings.positionFixed) {
    await windowManager.setAlignment(Alignment.bottomCenter);
  }
}

class DesktopLyricsWindowState extends ChangeNotifier {
  Map<String, Object?> _payload = const {};

  Map<String, Object?> get payload => _payload;

  void update(Map<String, Object?> payload) {
    _payload = payload;
    notifyListeners();
  }
}

class DesktopLyricsWindow extends StatelessWidget {
  final DesktopLyricsWindowState state;

  const DesktopLyricsWindow({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: DefaultTextStyle(
        style: _baseTextStyle,
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) =>
              _DesktopLyricsSurface(payload: state.payload),
        ),
      ),
    );
  }
}

class _DesktopLyricsSurface extends StatefulWidget {
  final Map<String, Object?> payload;

  const _DesktopLyricsSurface({required this.payload});

  @override
  State<_DesktopLyricsSurface> createState() => _DesktopLyricsSurfaceState();
}

class _DesktopLyricsSurfaceState extends State<_DesktopLyricsSurface> {
  Offset? _windowPosition;

  @override
  Widget build(BuildContext context) {
    final payload = widget.payload;
    final current = payload['currentLine'] as String? ?? '暂无歌词';
    final next = payload['nextLine'] as String? ?? '';
    final karaoke = payload['karaoke'] as bool? ?? false;
    final progress = ((payload['progress'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      1.0,
    );
    final configuredFontFamily = (payload['fontFamily'] as String?)?.trim();
    final fontFamily = configuredFontFamily?.isEmpty == true
        ? null
        : configuredFontFamily;
    final fontSize = (payload['fontSize'] as num?)?.toDouble() ?? 24;
    final textColor = _color(payload['textColor'] as num?, Colors.white);
    final highlightColor = _color(
      payload['highlightColor'] as num?,
      const Color(0xFF59F7E7),
    );
    final opacity = ((payload['backgroundOpacity'] as num?)?.toDouble() ?? 0.64)
        .clamp(0.0, 0.9);
    final draggable = payload['position'] == DesktopLyricsSettings.positionFree;

    final content = Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14 * opacity),
        ),
        boxShadow: opacity == 0
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.32 * opacity),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (karaoke)
            _HighlightText(
              text: current,
              progress: progress,
              fontFamily: fontFamily,
              fontSize: fontSize,
              baseColor: textColor,
              highlightColor: highlightColor,
            )
          else
            Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: highlightColor,
                decoration: TextDecoration.none,
                shadows: const [Shadow(color: Colors.black54, blurRadius: 5)],
              ),
            ),
          if (next.trim().isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              next,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize * 0.68,
                color: textColor.withValues(alpha: 0.62),
                decoration: TextDecoration.none,
                shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
          ],
        ],
      ),
    );
    return GestureDetector(
      onPanStart: draggable
          ? (_) async {
              _windowPosition = await windowManager.getPosition();
            }
          : null,
      onPanUpdate: draggable
          ? (details) {
              final origin = _windowPosition;
              if (origin == null) return;
              _windowPosition = origin + details.delta;
              unawaited(windowManager.setPosition(_windowPosition!));
            }
          : null,
      onPanEnd: draggable
          ? (_) {
              unawaited(_saveDraggedPosition());
            }
          : null,
      child: content,
    );
  }

  Future<void> _saveDraggedPosition() async {
    final position = await windowManager.getPosition();
    await _desktopLyricsChannel.invokeMethod<void>('draggedPosition', {
      'x': position.dx,
      'y': position.dy,
    });
  }

  Color _color(num? value, Color fallback) {
    final raw = value?.toInt();
    return raw == null ? fallback : Color(raw);
  }
}

class _HighlightText extends StatelessWidget {
  final String text;
  final double progress;
  final String? fontFamily;
  final double fontSize;
  final Color baseColor;
  final Color highlightColor;

  const _HighlightText({
    required this.text,
    required this.progress,
    required this.fontFamily,
    required this.fontSize,
    required this.baseColor,
    required this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      color: baseColor,
      decoration: TextDecoration.none,
      shadows: const [Shadow(color: Colors.black54, blurRadius: 5)],
    );
    // 逐字歌词由两层叠加：底层整行 + 上层按进度裁剪的高亮扫光。
    // Stack 必须收缩到歌词文字本身的宽度，两层才会完全重合 —— 如果外面套一个
    // 会撑满可用宽度的 Align，Stack 变宽后底字被居中、高亮层贴左侧边缘，
    // 同一句歌词就会出现在两个位置。
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: style,
        ),
        ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: progress,
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: style.copyWith(
                color: highlightColor,
                shadows: [Shadow(color: highlightColor, blurRadius: 10)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
