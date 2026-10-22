import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_layout_state.dart';
import '../../components/account/profile_account_card.dart';
import '../../components/index.dart';

/// 底部导航第 4 项「我的」入口页。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) {
        final bottomPadding = AppPageScaffold.scrollableBottomPadding(
          context,
          hasBottomNav: useBottomNavigation,
        );
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: '我的',
            showBackButton: !useBottomNavigation || AppLayoutSettings.isDesktop,
            backgroundColor: Colors.transparent,
            elevation: 0,
            actions: [
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_rounded),
                onPressed: () =>
                    Navigator.pushNamed(context, AppRoutes.settings),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
            children: [
              // 当前账号卡片（点击进入账号切换页）
              const ProfileAccountCard(),
              const SizedBox(height: 20),
              AppSettingSection(
                title: '资源库',
                children: [
                  _navTile(
                    context,
                    icon: Icons.album_rounded,
                    title: '专辑',
                    subtitle: '按专辑浏览歌曲',
                    route: AppRoutes.albums,
                  ),
                  _navTile(
                    context,
                    icon: Icons.people_rounded,
                    title: '歌手',
                    subtitle: '按歌手浏览歌曲',
                    route: AppRoutes.artists,
                  ),
                  _navTile(
                    context,
                    icon: Icons.music_video_rounded,
                    title: '风格',
                    subtitle: '按曲风分类浏览',
                    route: AppRoutes.genres,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '更多',
                children: [
                  _navTile(
                    context,
                    icon: Icons.history_rounded,
                    title: '最近播放',
                    subtitle: '播放历史',
                    route: AppRoutes.recent,
                  ),
                  _navTile(
                    context,
                    icon: Icons.bar_chart_rounded,
                    title: '听歌统计',
                    subtitle: '本地播放数据概览',
                    route: AppRoutes.listeningStats,
                  ),
                ],
              ),
            ],
          ),
          bottomNavIndex: useBottomNavigation ? 4 : null,
          onBottomNavTap: useBottomNavigation
              ? (index) => navigateToPrimaryDestination(context, index)
              : null,
        );
      },
    );
  }

  Widget _navTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return AppSettingTile(
      title: title,
      subtitle: subtitle,
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 20, color: scheme.primary),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.pushNamed(context, route),
    );
  }
}
