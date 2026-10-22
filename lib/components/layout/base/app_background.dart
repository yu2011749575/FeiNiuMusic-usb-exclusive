import 'dart:io';

import 'package:flutter/material.dart';
import 'dart:ui' as ui;

import '../../../app/state/settings_state.dart';

class AppBackground extends StatefulWidget {
  final Widget child;

  const AppBackground({super.key, required this.child});

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground> {
  // Cache the existence check so we don't hit the filesystem on every rebuild
  // (e.g. when only mask opacity or glow toggles change).
  String? _checkedPath;
  bool _checkedExists = false;

  bool _imageExists(String? path) {
    if (path == null || path.isEmpty) return false;
    if (path == _checkedPath) return _checkedExists;
    _checkedPath = path;
    _checkedExists = File(path).existsSync();
    return _checkedExists;
  }

  @override
  void initState() {
    super.initState();
    AppBackgroundSettings.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    Widget buildBackground() {
      return AnimatedBuilder(
        animation: Listenable.merge([
          AppBackgroundSettings.backgroundImagePath,
          AppBackgroundSettings.backgroundMaskOpacity,
          AppBackgroundSettings.backgroundBlurSigma,
          AppBackgroundSettings.pageGlowEnabled,
      ]),
      builder: (context, _) {
        final path = AppBackgroundSettings.backgroundImagePath.value;
        final maskOpacity = AppBackgroundSettings.backgroundMaskOpacity.value;
        final blurSigma = AppBackgroundSettings.backgroundBlurSigma.value;
        final glowEnabled = AppBackgroundSettings.pageGlowEnabled.value;
        final imagePath = path;
        final hasImage =
            imagePath != null &&
            imagePath.isNotEmpty &&
            _imageExists(imagePath);
        final baseColor = theme.scaffoldBackgroundColor;
        final maskColor = theme.scaffoldBackgroundColor.withValues(
          alpha: maskOpacity,
        );
        final targetWidth =
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .round();
        final resolvedBlur = blurSigma;
        return Container(
          color: baseColor,
          child: Stack(
            children: [
              if (hasImage)
                Positioned.fill(
                  child: RepaintBoundary(
                    child: resolvedBlur > 0.1
                        ? ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: resolvedBlur,
                              sigmaY: resolvedBlur,
                            ),
                            child: Image.file(
                              File(imagePath),
                              fit: BoxFit.cover,
                              cacheWidth: targetWidth,
                            ),
                          )
                        : Image.file(
                            File(imagePath),
                            fit: BoxFit.cover,
                            cacheWidth: targetWidth,
                          ),
                  ),
                ),
              if (glowEnabled)
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: _buildGlowGradient(
                            colorScheme,
                            isDark: isDark,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (hasImage && maskOpacity > 0)
                Positioned.fill(child: ColoredBox(color: maskColor)),
              widget.child,
            ],
          ),
        );
      },
      );
    }

    return buildBackground();
  }

  /// Soft top→bottom wash tinted by the current theme's primary color.
  ///
  /// Covers the full page (not just the top) so that transparent panels
  /// anywhere on screen have something colored to show through — otherwise
  /// panels below ~55% of the viewport would just reveal a flat white
  /// scaffold and the transparency slider would look broken.
  LinearGradient _buildGlowGradient(
    ColorScheme colorScheme, {
    required bool isDark,
  }) {
    final topStrength = isDark ? 0.24 : 0.18;
    final midStrength = isDark ? 0.14 : 0.10;
    final bottomStrength = isDark ? 0.08 : 0.06;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        colorScheme.primary.withValues(alpha: topStrength),
        colorScheme.primary.withValues(alpha: midStrength),
        colorScheme.primary.withValues(alpha: bottomStrength),
      ],
      stops: const [0.0, 0.5, 1.0],
    );
  }
}
