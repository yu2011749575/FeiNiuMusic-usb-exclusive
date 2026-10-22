import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/feiniu/account_entry.dart';
import 'package:feiniu_music/app/services/feiniu/account_store.dart';
import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/auth_service.dart';
import 'package:feiniu_music/app/state/settings_fn_state.dart';

/// 构造拦截器短路返回的 Dio（沿用 transcode_service_test 的 mock 模式）。
Dio _mockDio(dynamic Function(RequestOptions) respond) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: respond(options),
          ),
        );
      },
    ),
  );
  return dio;
}

/// 模拟一次成功的密码登录响应（userToken 可注入）。
/// FeiNiuResponse 包裹 data 段，data 内含 userToken 与 user。
Map<String, dynamic> _loginResp(String token) => {
      'code': 0,
      'msg': 'ok',
      'data': {
        'userToken': token,
        'user': {'name': 'user-a'},
      },
    };

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

  test('empty init → empty accounts and no current', () async {
    await AccountStore.instance.init();

    expect(AccountStore.instance.accounts.value, isEmpty);
    expect(AccountStore.instance.currentAccountId.value, isNull);
  });

  test('first-run migration imports live token slot as first account', () async {
    SharedPreferences.setMockInitialValues({
      'feiniu_music_token': 'token-a',
      'feiniu_server_url': 'https://192.168.1.10:5667',
      'feiniu_username': 'user-a',
    });
    await FeiNiuApiClient.instance.tryLoadAuth();

    await AccountStore.instance.init();

    expect(AccountStore.instance.accounts.value, hasLength(1));
    final acc = AccountStore.instance.accounts.value.first;
    expect(acc.username, 'user-a');
    expect(acc.token, 'token-a');
    expect(acc.serverUrl, 'https://192.168.1.10:5667');
    expect(AccountStore.instance.currentAccountId.value, acc.id);
  });

  test('addOrUpdate dedups by server+user and preserves custom name', () async {
    await AccountStore.instance.init();

    final first = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(
        name: '自宅',
        serverUrl: 'https://h:5667',
        username: 'u',
        token: 't1',
      ),
    );
    expect(first.name, '自宅');

    // 同一服务器 + 同一用户名的再次登录：保留备注，覆盖 token
    final updated = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(
        id: 'ignored-id',
        name: '',
        serverUrl: 'https://h:5667',
        username: 'u',
        token: 't2',
      ),
    );

    expect(AccountStore.instance.accounts.value, hasLength(1));
    expect(updated.id, first.id);
    expect(updated.name, '自宅');
    expect(updated.token, 't2');
  });

  test('addOrUpdate keeps same username on different servers as separate', () async {
    await AccountStore.instance.init();

    await AccountStore.instance.addOrUpdate(
      AccountEntry.build(serverUrl: 'https://a:5667', username: 'u', token: 't'),
    );
    await AccountStore.instance.addOrUpdate(
      AccountEntry.build(serverUrl: 'https://b:5667', username: 'u', token: 't'),
    );

    expect(AccountStore.instance.accounts.value, hasLength(2));
  });

  test('同主机 HTTP/HTTPS 视为两个独立账号（互不覆盖）', () async {
    await AccountStore.instance.init();

    final http = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(serverUrl: 'http://h:5666', username: 'u', token: 't1'),
    );
    final https = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(serverUrl: 'https://h:5667', username: 'u', token: 't2'),
    );

    expect(AccountStore.instance.accounts.value, hasLength(2));
    expect(http.id, isNot(https.id));
    expect(https.token, 't2');
    expect(http.token, 't1', reason: 'HTTP 账号不应被 HTTPS 登录覆盖');
  });

  group('serverLabel 区分 HTTP/HTTPS', () {
    test('地址账号显示 scheme://host:port', () {
      expect(
        AccountEntry.build(serverUrl: 'http://h:5666', username: 'u').serverLabel,
        'http://h:5666',
      );
      expect(
        AccountEntry.build(serverUrl: 'https://h:5667', username: 'u').serverLabel,
        'https://h:5667',
      );
      expect(
        AccountEntry.build(
          serverUrl: 'https://[2001:db8::1]:5667',
          username: 'u',
        ).serverLabel,
        'https://[2001:db8::1]:5667',
      );
    });

    test('FNID 账号仍只显示 FNID', () {
      expect(
        AccountEntry.build(
          serverUrl: 'https://h:5667',
          username: 'u',
          fnId: 'abc.5ddd.com',
        ).serverLabel,
        'abc',
      );
    });
  });

  group('FNID 维度去重（重连换地址不产生新账号）', () {
    test('identityKey 相同 FNID + 用户名即使 serverUrl 不同也视为同一账号', () async {
      await AccountStore.instance.init();

      // 同一 FNID，但探测地址变了（内网 IP → 中继）
      final first = await AccountStore.instance.addOrUpdate(
        AccountEntry.build(
          fnId: 'fnid-a',
          serverUrl: 'https://192.168.1.10:5667',
          username: 'u',
          token: 't1',
        ),
      );
      final second = await AccountStore.instance.addOrUpdate(
        AccountEntry.build(
          fnId: 'fnid-a',
          serverUrl: 'https://abc.5ddd.com',
          username: 'u',
          token: 't2',
        ),
      );

      // 去重命中同一账号：仅更新地址与 token，不新增条目
      expect(AccountStore.instance.accounts.value, hasLength(1));
      expect(second.id, first.id);
      expect(second.serverUrl, 'https://abc.5ddd.com');
      expect(second.token, 't2');
    });

    test('不同 FNID 的账号保持独立', () async {
      await AccountStore.instance.init();

      await AccountStore.instance.addOrUpdate(
        AccountEntry.build(fnId: 'fnid-a', serverUrl: 'https://a.5ddd.com', username: 'u', token: 't'),
      );
      await AccountStore.instance.addOrUpdate(
        AccountEntry.build(fnId: 'fnid-b', serverUrl: 'https://b.5ddd.com', username: 'u', token: 't'),
      );

      expect(AccountStore.instance.accounts.value, hasLength(2));
    });

    test('无 FNID 时仍按 serverUrl 去重（回退行为）', () async {
      await AccountStore.instance.init();

      await AccountStore.instance.addOrUpdate(
        AccountEntry.build(serverUrl: 'https://x:5667', username: 'u', token: 't1'),
      );
      await AccountStore.instance.addOrUpdate(
        AccountEntry.build(serverUrl: 'https://y:5667', username: 'u', token: 't2'),
      );

      expect(AccountStore.instance.accounts.value, hasLength(2));
    });

    test('合并历史重复 FNID 账号：init 时收敛，保留 token 非空的条目', () async {
      // 模拟 1.3.5 之前积累的重复条目：同一 FNID + 用户名，地址不同
      final now = DateTime.now();
      final legacyAccounts = [
        // 有 token（当前有效会话）
        {
          'id': 'dup-old',
          'name': '客厅 NAS',
          'serverUrl': 'https://192.168.1.10:5667',
          'username': 'u',
          'password': 'pw',
          'token': 't-old',
          'relayMode': false,
          'fnId': 'fnid-a',
          'createdAtMs': now.subtract(const Duration(days: 30)).millisecondsSinceEpoch,
        },
        // 无 token（登录过期），较新
        {
          'id': 'dup-new',
          'name': '',
          'serverUrl': 'https://abc.5ddd.com',
          'username': 'u',
          'password': 'pw',
          'token': '',
          'relayMode': true,
          'fnId': 'fnid-a',
          'createdAtMs': now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        },
      ];
      SharedPreferences.setMockInitialValues({
        'feiniu_accounts_v1': jsonEncode(legacyAccounts),
        'feiniu_current_account_id': 'dup-new',
      });

      await AccountStore.instance.init();

      // 合并为一条：保留 token 非空的 dup-old，currentAccountId 指向它
      expect(AccountStore.instance.accounts.value, hasLength(1));
      final kept = AccountStore.instance.accounts.value.first;
      expect(kept.id, 'dup-old');
      expect(kept.token, 't-old');
      expect(kept.serverUrl, 'https://192.168.1.10:5667');
      expect(AccountStore.instance.currentAccountId.value, 'dup-old');
    });

    test('合并历史重复 FNID 账号：保留条目无备注时继承被删条目的备注', () async {
      final now = DateTime.now();
      final legacyAccounts = [
        {
          'id': 'winner',
          'name': '',
          'serverUrl': 'https://192.168.1.10:5667',
          'username': 'u',
          'token': 't-winner',
          'relayMode': false,
          'fnId': 'fnid-b',
          'createdAtMs': now.subtract(const Duration(days: 10)).millisecondsSinceEpoch,
        },
        {
          'id': 'loser-named',
          'name': '书房 NAS',
          'serverUrl': 'https://abc.5ddd.com',
          'username': 'u',
          'token': '',
          'relayMode': true,
          'fnId': 'fnid-b',
          'createdAtMs': now.millisecondsSinceEpoch,
        },
      ];
      SharedPreferences.setMockInitialValues({
        'feiniu_accounts_v1': jsonEncode(legacyAccounts),
        'feiniu_current_account_id': 'winner',
      });

      await AccountStore.instance.init();

      expect(AccountStore.instance.accounts.value, hasLength(1));
      final kept = AccountStore.instance.accounts.value.first;
      expect(kept.id, 'winner');
      expect(kept.name, '书房 NAS', reason: '被删条目的备注应合并进保留条目');
    });

    test('非 FNID 账号不受合并影响', () async {
      final now = DateTime.now();
      final legacyAccounts = [
        {
          'id': 'manual-a',
          'name': '',
          'serverUrl': 'https://x:5667',
          'username': 'u',
          'token': 't',
          'relayMode': false,
          'createdAtMs': now.subtract(const Duration(days: 5)).millisecondsSinceEpoch,
        },
        {
          'id': 'manual-b',
          'name': '',
          'serverUrl': 'https://y:5667',
          'username': 'u',
          'token': 't',
          'relayMode': false,
          'createdAtMs': now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        },
      ];
      SharedPreferences.setMockInitialValues({
        'feiniu_accounts_v1': jsonEncode(legacyAccounts),
        'feiniu_current_account_id': 'manual-a',
      });

      await AccountStore.instance.init();

      // 手动地址账号（无 FNID）保持两条（不同服务器是不同账号）
      expect(AccountStore.instance.accounts.value, hasLength(2));
    });
  });

  test('rename and remove persist; remove current falls back to first', () async {
    await AccountStore.instance.init();

    final a = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(
        serverUrl: 'https://a:5667',
        username: 'u1',
        token: 't',
      ),
    );
    final b = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(
        serverUrl: 'https://b:5667',
        username: 'u2',
        token: 't',
      ),
    );

    await AccountStore.instance.rename(a.id, '新备注');
    expect(AccountStore.instance.byId(a.id)!.name, '新备注');

    AccountStore.instance.currentAccountId.value = b.id;
    await AccountStore.instance.remove(b.id);

    expect(AccountStore.instance.byId(b.id), isNull);
    expect(AccountStore.instance.currentAccountId.value, a.id);
  });

  test('activate writes active slot prefs and sets AuthService notifiers', () async {
    await AccountStore.instance.init();

    final entry = AccountEntry.build(
      name: 'X',
      serverUrl: 'https://x:5667',
      username: 'ux',
      password: 'pw',
      token: 'tok',
      relayMode: true,
      accessCode: 'code',
      fnId: 'fnid',
    );
    await AccountStore.instance.activate(entry);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('feiniu_music_token'), 'tok');
    expect(prefs.getString('feiniu_server_url'), 'https://x:5667');
    expect(prefs.getBool('feiniu_relay_mode'), true);
    expect(prefs.getString('feiniu_username'), 'ux');
    expect(prefs.getString('feiniu_password'), 'pw');
    expect(prefs.getString('fn_access_code'), 'code');

    expect(AuthService.instance.serverUrl.value, 'https://x:5667');
    expect(AuthService.instance.username.value, 'ux');
    expect(AuthService.instance.isLoggedIn.value, true);
  });

  test('updateServerUrl clears token when URL changes', () async {
    await AccountStore.instance.init();

    final a = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(
        serverUrl: 'https://old:5667',
        username: 'u1',
        token: 'tok',
      ),
    );

    await AccountStore.instance.updateServerUrl(a.id, 'https://new:5667/');

    expect(AccountStore.instance.byId(a.id)!.serverUrl, 'https://new:5667');
    expect(AccountStore.instance.byId(a.id)!.token, '');
  });

  test('updateServerUrl treats non-URL input as FNID', () async {
    await AccountStore.instance.init();

    final a = await AccountStore.instance.addOrUpdate(
      AccountEntry.build(
        fnId: 'oldid',
        serverUrl: 'https://oldid.5ddd.com',
        username: 'u1',
        token: 'tok',
      ),
    );

    // 输入带后缀的 FNID → 只保留 id 部分
    await AccountStore.instance.updateServerUrl(a.id, 'newid.5ddd.com');
    expect(AccountStore.instance.byId(a.id)!.fnId, 'newid');
    expect(AccountStore.instance.byId(a.id)!.token, '');

    // 输入完整 URL → 更新 serverUrl 并清除 FNID
    await AccountStore.instance.updateServerUrl(a.id, 'https://x:5667');
    final updated = AccountStore.instance.byId(a.id)!;
    expect(updated.serverUrl, 'https://x:5667');
    expect(updated.fnId, isNull);
  });

  test('persistLogin stores provided name; re-login keeps non-empty name', () async {
    await AccountStore.instance.init();
    await FeiNiuApiClient.instance.setAuth('https://s:5667', 'tok');

    final first = await AccountStore.instance.persistLogin(
      serverUrl: 'https://s:5667',
      username: 'u',
      password: 'pw',
      relayMode: false,
      name: '客厅 NAS',
    );
    expect(first.name, '客厅 NAS');

    // 再次登录同一账号但未填备注（name 为空）：保留原有备注
    final second = await AccountStore.instance.persistLogin(
      serverUrl: 'https://s:5667',
      username: 'u',
      password: 'pw',
      relayMode: false,
    );
    expect(second.id, first.id);
    expect(second.name, '客厅 NAS');

    // 明确填写了新备注：以本次为准
    final third = await AccountStore.instance.persistLogin(
      serverUrl: 'https://s:5667',
      username: 'u',
      password: 'pw',
      relayMode: false,
      name: '书房',
    );
    expect(third.id, first.id);
    expect(third.name, '书房');
  });

  group('handleTokenExpired', () {
    test('有保存密码且重登成功 → token 刷新、保持登录态、不打断会话', () async {
      await AccountStore.instance.init();

      // 造一个带密码的当前账号，并注入成功的登录响应
      await FeiNiuApiClient.instance.setAuth('https://s:5667', 'stale-token');
      final a = await AccountStore.instance.persistLogin(
        serverUrl: 'https://s:5667',
        username: 'user-a',
        password: 'pw-a',
        relayMode: false,
      );
      AccountStore.instance.currentAccountId.value = a.id;
      FeiNiuApiClient.instance.setDioForTest(_mockDio((o) => _loginResp('fresh-token')));

      final result = await AccountStore.instance.handleTokenExpired();

      expect(result, isTrue, reason: '重登成功应保持登录');
      expect(FeiNiuApiClient.instance.token, 'fresh-token', reason: 'API 客户端应换上新 token');
      expect(AuthService.instance.isLoggedIn.value, isTrue, reason: '不应跳回登录页');
      expect(AccountStore.instance.byId(a.id)!.token, 'fresh-token', reason: '账号应更新 token');
    });

    test('无保存密码 → 强制登出、isLoggedIn=false、保留凭据供登录页预填', () async {
      await AccountStore.instance.init();

      final a = await AccountStore.instance.addOrUpdate(
        AccountEntry.build(
          serverUrl: 'https://s:5667',
          username: 'user-a',
          token: 'stale-token',
        ),
      );
      AccountStore.instance.currentAccountId.value = a.id;
      await FeiNiuApiClient.instance.setAuth('https://s:5667', 'stale-token');
      AuthService.instance.isLoggedIn.value = true;

      final result = await AccountStore.instance.handleTokenExpired();

      expect(result, isFalse, reason: '无密码应登出');
      expect(AuthService.instance.isLoggedIn.value, isFalse, reason: '应触发登录页门控');
      expect(FeiNiuApiClient.instance.token, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('feiniu_server_url'), 'https://s:5667', reason: '保留服务器供预填');
      expect(prefs.getString('feiniu_username'), 'user-a', reason: '保留用户名供预填');
      expect(AccountStore.instance.byId(a.id)!.token, '', reason: '账号 token 应被清空');
    });

    test('有密码但重登失败 → 回退强制登出', () async {
      await AccountStore.instance.init();

      await FeiNiuApiClient.instance.setAuth('https://s:5667', 'stale-token');
      final a = await AccountStore.instance.persistLogin(
        serverUrl: 'https://s:5667',
        username: 'user-a',
        password: 'pw-a',
        relayMode: false,
      );
      AccountStore.instance.currentAccountId.value = a.id;
      // 重登返回业务错误（如账号被禁用）
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) => {'code': 120001, 'msg': '用户名或密码错误'}),
      );
      AuthService.instance.isLoggedIn.value = true;

      final result = await AccountStore.instance.handleTokenExpired();

      expect(result, isFalse, reason: '重登失败应登出');
      expect(AuthService.instance.isLoggedIn.value, isFalse);
      expect(AccountStore.instance.byId(a.id)!.token, '');
    });
  });
}
