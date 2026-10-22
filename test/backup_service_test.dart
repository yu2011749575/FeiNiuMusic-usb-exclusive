import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/backup/backup_service.dart';
import 'package:feiniu_music/app/services/feiniu/account_entry.dart';
import 'package:feiniu_music/app/services/feiniu/account_store.dart';
import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/auth_service.dart';
import 'package:feiniu_music/app/state/settings_fn_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppFnConnectionSettings.resetForTest();
    AccountStore.instance.resetForTest();
    FeiNiuApiClient.instance.clearAuth();
    AuthService.instance.serverUrl.value = null;
    AuthService.instance.username.value = null;
    AuthService.instance.isLoggedIn.value = false;
  });

  tearDown(() {
    AccountStore.instance.resetForTest();
  });

  group('备份分块默认值（修复2：应用设置默认勾选）', () {
    test('BackupSections 默认包含应用设置', () {
      const s = BackupSections();
      expect(s.accounts, isTrue);
      expect(s.stats, isTrue);
      expect(s.settings, isTrue);
    });

    test('无存档时 loadSections 默认包含应用设置', () async {
      final s = await BackupService.instance.loadSections();
      expect(s.settings, isTrue);
    });

    test('历史存档显式关闭应用设置 → 保持用户选择', () async {
      SharedPreferences.setMockInitialValues({
        'backup_sections_v1': jsonEncode({
          'accounts': true,
          'stats': true,
          'settings': false,
        }),
      });
      final s = await BackupService.instance.loadSections();
      expect(s.settings, isFalse);
    });
  });

  group('账号 + 设置备份/还原（修复1：还原当前激活账号）', () {
    test('备份含 currentAccountId，还原恢复账号列表与登录态', () async {
      // ---- 源设备：两个账号，第一个是当前账号 ----
      await AccountStore.instance.init();
      final a = await AccountStore.instance.addOrUpdate(
        AccountEntry.build(
          name: '客厅 NAS',
          serverUrl: 'https://a:5667',
          username: 'u1',
          password: 'pw1',
          token: 'tok-a',
          accessCode: 'code',
          fnId: 'fnid-a',
        ),
      );
      await AccountStore.instance.addOrUpdate(
        AccountEntry.build(
          serverUrl: 'https://b:5667',
          username: 'u2',
          password: 'pw2',
          token: 'tok-b',
        ),
      );
      AccountStore.instance.currentAccountId.value = a.id;

      // 造几条应用设置
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('setting_track_change_notify', true);
      await prefs.setInt('match_concurrency', 5);
      await prefs.setStringList('match_sources_order', ['netease', 'qq']);

      // ---- 导出 ----
      final jsonStr = await BackupService.instance.buildBackupJson(
        const BackupSections(accounts: true, stats: false, settings: true),
      );
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(data['currentAccountId'], a.id, reason: '备份应记录当前激活账号');
      expect((data['accounts'] as List), hasLength(2));
      expect((data['settings'] as Map).containsKey('setting_track_change_notify'),
          isTrue);

      // ---- 目标设备：全新状态，导入 ----
      AccountStore.instance.resetForTest();
      SharedPreferences.setMockInitialValues({});
      FeiNiuApiClient.instance.clearAuth();
      AuthService.instance.serverUrl.value = null;
      AuthService.instance.username.value = null;
      AuthService.instance.isLoggedIn.value = false;

      final summary = await BackupService.instance.restoreFromJson(jsonStr);
      expect(summary, contains('账号'));
      expect(summary, contains('应用设置'));

      // 账号列表还原，且备份里的当前账号自动激活（登录态恢复）
      final store = AccountStore.instance;
      expect(store.accounts.value, hasLength(2));
      expect(store.accounts.value.map((e) => e.username), containsAll(['u1', 'u2']));
      final restored = store.byId(a.id);
      expect(restored, isNotNull);
      expect(restored!.name, '客厅 NAS');
      expect(restored.token, 'tok-a');
      expect(store.currentAccountId.value, restored.id, reason: '还原后应保持为当前账号');

      final prefs2 = await SharedPreferences.getInstance();
      expect(prefs2.getString('feiniu_music_token'), 'tok-a', reason: '会话槽位应回填');
      expect(prefs2.getString('feiniu_server_url'), 'https://a:5667');
      expect(prefs2.getBool('feiniu_relay_mode'), false);
      expect(prefs2.getString('fn_access_code'), 'code');
      expect(AuthService.instance.isLoggedIn.value, isTrue, reason: '还原后应处于登录态');

      // 应用设置还原
      expect(prefs2.getBool('setting_track_change_notify'), isTrue);
      expect(prefs2.getInt('match_concurrency'), 5);
      expect(prefs2.getStringList('match_sources_order'), ['netease', 'qq']);
    });

    test('还原到已有同身份账号的设备：按备份 id 兜底仍激活正确账号', () async {
      // 目标设备已有同 FNID + 用户名（本地 id 与备份不同）
      await AccountStore.instance.init();
      final localA = await AccountStore.instance.addOrUpdate(
        AccountEntry.build(
          serverUrl: 'https://a:5667',
          username: 'u1',
          token: 'local-token',
          fnId: 'fnid-a',
        ),
      );
      expect(localA.id, isNotEmpty);

      // 构造一份备份：当前账号是「备份设备上的 id」= other-id
      final backup = jsonEncode({
        'format': 1,
        'app': 'feiniu_music',
        'sections': {'accounts': true, 'stats': false, 'settings': false},
        'accounts': [
          {
            'id': 'backup-id-a',
            'name': '客厅 NAS',
            'serverUrl': 'https://a:5667',
            'username': 'u1',
            'password': 'pw1',
            'token': 'tok-a',
            'relayMode': false,
            'accessCode': 'code',
            'fnId': 'fnid-a',
          },
        ],
        'currentAccountId': 'backup-id-a',
      });

      final summary = await BackupService.instance.restoreFromJson(backup);
      expect(summary, contains('账号'));

      // 同身份合并为一条；currentAccountId 指向合并后的本地条目
      final store = AccountStore.instance;
      expect(store.accounts.value, hasLength(1));
      final merged = store.accounts.value.first;
      expect(merged.id, localA.id, reason: '同身份应保留本地 id');
      expect(merged.token, 'tok-a');
      expect(store.currentAccountId.value, merged.id,
          reason: '备份当前账号应激活到合并后的条目');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('feiniu_music_token'), 'tok-a');
      expect(AuthService.instance.isLoggedIn.value, isTrue);
    });

    test('只备份设置时，不触碰当前账号（currentAccountId 不导出）', () async {
      // 目标设备有当前账号
      await AccountStore.instance.init();
      final a = await AccountStore.instance.addOrUpdate(
        AccountEntry.build(serverUrl: 'https://a:5667', username: 'u1', token: 't'),
      );
      AccountStore.instance.currentAccountId.value = a.id;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('setting_tablet_mode', true);

      // 仅设置备份：accounts=false
      final jsonStr = await BackupService.instance.buildBackupJson(
        const BackupSections(accounts: false, stats: false, settings: true),
      );
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(data.containsKey('accounts'), isFalse);
      expect(data.containsKey('currentAccountId'), isFalse,
          reason: '未选账号分块时不应导出当前账号');

      // 还原仅设置：当前账号保持不动
      AccountStore.instance.resetForTest();
      SharedPreferences.setMockInitialValues({});
      await AccountStore.instance.init();
      final b = await AccountStore.instance.addOrUpdate(
        AccountEntry.build(serverUrl: 'https://b:5667', username: 'u2', token: 'tb'),
      );
      AccountStore.instance.currentAccountId.value = b.id;

      await BackupService.instance.restoreFromJson(jsonStr);

      expect(AccountStore.instance.currentAccountId.value, b.id,
          reason: '设置还原不应改动当前账号');
      final prefs2 = await SharedPreferences.getInstance();
      expect(prefs2.getBool('setting_tablet_mode'), isTrue);
      expect(prefs2.getString('feiniu_music_token'), isNull,
          reason: '仅设置还原不应注入会话凭据');
    });
  });
}
