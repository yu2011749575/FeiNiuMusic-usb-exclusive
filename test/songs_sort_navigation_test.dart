import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:feiniu_music/app/services/db/db_helper.dart';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/utils/primary_shell_scope.dart';
import 'package:feiniu_music/components/layout/modern_navigation_bar.dart';
import 'package:feiniu_music/pages/songs/songs_page.dart';

Future<void> pumpPage(WidgetTester tester) async {
  // 页面有持续动画，按固定帧数推进而不等待动画停止。
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('cached songs tab reloads the latest saved sort on reentry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'songs_sort_key': 'duration',
      'songs_sort_asc': false,
    });
    AppLayoutSettings.resetForTest();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    DbHelper.instance.resetForTest(overridePath: inMemoryDatabasePath);
    await tester.runAsync(() async {
      await DbHelper.instance.database;
    });
    addTearDown(() => DbHelper.instance.resetForTest());
    final sorts = <String>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/track/list')) {
            sorts.add(options.queryParameters['sort'] as String);
          }
          handler.resolve(
            Response(
              requestOptions: options,
              data: {
                'code': 0,
                'data': {'list': [], 'total': 0},
              },
            ),
          );
        },
      ),
    );
    FeiNiuApiClient.instance.setDioForTest(dio);
    final index = ValueNotifier(2);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (context, value, child) => PrimaryShellMarker(
            child: PrimaryNavigationScope(
              currentIndex: value,
              onSelected: (value) => index.value = value,
              child: IndexedStack(
                index: value == 2 ? 0 : 1,
                children: const [SongsPage(), SizedBox()],
              ),
            ),
          ),
        ),
      ),
    );
    await pumpPage(tester);
    expect(sorts, ['createdAt,desc']);
    final originalState = tester.state(find.byType(SongsPage));
    index.value = 0;
    await pumpPage(tester);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('songs_sort_key', 'title');
    await prefs.setBool('songs_sort_asc', true);
    index.value = 2;
    await pumpPage(tester);
    expect(tester.state(find.byType(SongsPage)), same(originalState));
    expect(sorts.last, 'title,asc');
    index.value = 0;
    await pumpPage(tester);
    index.value = 2;
    await pumpPage(tester);
    expect(sorts.last, 'title,asc');
    await tester.pumpWidget(const SizedBox());
    await pumpPage(tester);
    index.dispose();
  });
}
