import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_island_lyric.dart';
import 'package:feiniu_music/components/index.dart';

/// 回归测试：灵动岛设置区块里，
/// 子选项（显示播放进度等）随「灵动岛歌词」主开关显示/隐藏，
/// 且主开关开启时子开关可独立点击（onChanged 非空）。
///
/// 直接从 components 构建区块（不依赖设置页的完整异步加载），
/// 专注验证 UI 交互性。持久化行为由 test/settings_island_lyric_test.dart 覆盖。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IslandLyricSettings.resetForTest();
  });

  Widget buildSection() {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            AppSettingSection(
              title: '通知歌词灵动岛',
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: IslandLyricSettings.enabled,
                  builder: (context, enabled, _) {
                    return AppSettingSwitchTile(
                      title: '灵动岛歌词',
                      value: enabled,
                      onChanged: (value) {
                        IslandLyricSettings.setEnabled(value);
                      },
                    );
                  },
                ),
                // 子选项随主开关显示/隐藏（与页面实现一致）
                ValueListenableBuilder<bool>(
                  valueListenable: IslandLyricSettings.enabled,
                  builder: (context, enabled, _) {
                    if (!enabled) return const SizedBox.shrink();
                    return Column(
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: IslandLyricSettings.showProgress,
                          builder: (context, showProgress, _) {
                            return AppSettingSwitchTile(
                              title: '显示播放进度',
                              value: showProgress,
                              onChanged: (value) {
                                IslandLyricSettings.setShowProgress(value);
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
      ),
    );
  }

  testWidgets('主开关关闭时子选项隐藏', (tester) async {
    await tester.pumpWidget(buildSection());
    await tester.pump();

    expect(IslandLyricSettings.enabled.value, isFalse);
    expect(find.text('显示播放进度'), findsNothing,
        reason: '主开关关闭时子选项应隐藏');
  });

  testWidgets('主开关开启时子选项显示且可独立点击', (tester) async {
    await tester.pumpWidget(buildSection());
    await tester.pump();

    // 打开主开关
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(IslandLyricSettings.enabled.value, isTrue);

    // 子选项出现
    final progressTileText = find.text('显示播放进度');
    expect(progressTileText, findsOneWidget);

    // 该行 Switch 可交互（onChanged 非空）
    final progressSwitchWidget = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: progressTileText,
          matching: find.byType(ListTile),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(progressSwitchWidget.onChanged, isNotNull,
        reason: '主开关开启时「显示播放进度」应可独立点击');
  });
}
