import 'package:flutter/material.dart';

import '../../app/services/android_platform_service.dart';
import '../../app/services/track_change_overlay_service.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  bool _supportsCustomActions = true;

  @override
  void initState() {
    super.initState();
    MediaNotificationSettings.ensureLoaded();
    AppLayoutSettings.ensureLoaded();
    _loadCapabilities();
  }

  Future<void> _loadCapabilities() async {
    final supported = await AndroidPlatformService.instance
        .supportsNotificationCustomActions();
    if (!mounted) return;
    setState(() => _supportsCustomActions = supported);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '通知设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '媒体通知',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.showLyrics,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '通知显示歌词',
                    subtitle: '在媒体通知里显示当前歌词行',
                    value: enabled,
                    onChanged: (value) {
                      MediaNotificationSettings.setShowLyrics(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.lyricOnTop,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '歌词首行显示',
                    subtitle: '上方歌词，下方歌名与歌手名',
                    value: enabled,
                    onChanged: (value) {
                      MediaNotificationSettings.setLyricOnTop(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.showCloseAction,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '显示关闭按钮',
                    subtitle: _supportsCustomActions
                        ? '在通知上展示关闭应用按钮'
                        : '当前设备暂不可用自定义通知按钮',
                    value: _supportsCustomActions && enabled,
                    onChanged: _supportsCustomActions
                        ? (value) {
                            MediaNotificationSettings.setShowCloseAction(value);
                          }
                        : null,
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.showFavoriteAction,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '显示收藏按钮',
                    subtitle: _supportsCustomActions
                        ? '在通知上展示收藏/取消收藏'
                        : '当前设备暂不可用自定义通知按钮',
                    value: _supportsCustomActions && enabled,
                    onChanged: _supportsCustomActions
                        ? (value) {
                            MediaNotificationSettings.setShowFavoriteAction(
                              value,
                            );
                          }
                        : null,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            title: '切歌弹窗',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppLayoutSettings.trackChangeNotify,
                builder: (context, enabled, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppSettingSwitchTile(
                        title: '切歌弹窗',
                        subtitle: enabled
                            ? '切换歌曲时在界面顶部弹出正在播放的歌曲信息'
                            : '切换歌曲时不弹出提示',
                        value: enabled,
                        onChanged: (value) {
                          AppLayoutSettings.setTrackChangeNotify(value);
                        },
                      ),
                      if (enabled)
                        ValueListenableBuilder<bool>(
                          valueListenable:
                              AppLayoutSettings.trackChangeOverlayNotify,
                          builder: (context, overlayEnabled, _) {
                            return AppSettingSwitchTile(
                              title: '应用外通知',
                              subtitle: overlayEnabled
                                  ? '后台播放切歌时用悬浮窗显示（需悬浮窗权限）'
                                  : '仅在应用前台显示切歌卡片',
                              value: overlayEnabled,
                              onChanged: (value) async {
                                await AppLayoutSettings
                                    .setTrackChangeOverlayNotify(value);
                                // 开启子开关时若无悬浮窗权限，引导授权一次（失败静默）。
                                if (value &&
                                    !await TrackChangeOverlayService
                                        .hasOverlayPermission()) {
                                  await TrackChangeOverlayService
                                      .openOverlaySettings();
                                }
                              },
                            );
                          },
                        ),
                      if (enabled)
                        ValueListenableBuilder<int>(
                          valueListenable:
                              AppLayoutSettings.trackChangeToastDurationMs,
                          builder: (context, ms, _) {
                            final seconds = (ms / 1000).round();
                            return AppSettingSlider(
                              title: '提示时长',
                              value: seconds.toDouble(),
                              min: 2,
                              max: 10,
                              divisions: 8,
                              valueText: '$seconds秒',
                              onChanged: (next) {
                                AppLayoutSettings
                                    .setTrackChangeToastDurationMs(
                                      (next * 1000).round(),
                                    );
                              },
                            );
                          },
                        ),
                      if (enabled)
                        ValueListenableBuilder<double>(
                          valueListenable:
                              AppLayoutSettings.trackChangeToastScale,
                          builder: (context, scale, _) {
                            return AppSettingSlider(
                              title: '卡片大小',
                              value: scale,
                              min: 1,
                              max: 3,
                              divisions: 20,
                              valueText: '${scale.toStringAsFixed(1)}×',
                              onChanged: (next) {
                                AppLayoutSettings.setTrackChangeToastScale(next);
                              },
                            );
                          },
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
