import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/feiniu/fn_connection_probe_service.dart';
import 'package:feiniu_music/app/services/feiniu/fn_models.dart';
import 'package:feiniu_music/app/state/settings_fn_state.dart';

void main() {
  tearDown(() {
    AppFnConnectionSettings.resetForTest();
  });

  test('no stored order → default order', () async {
    SharedPreferences.setMockInitialValues({});

    await AppFnConnectionSettings.ensureLoaded();

    expect(
      AppFnConnectionSettings.connectionOrder.value,
      kDefaultConnectionOrder,
    );
  });

  test('stored order is normalized', () async {
    SharedPreferences.setMockInitialValues({
      'fn_connection_order': ['publicIPv4', 'relay'],
    });

    await AppFnConnectionSettings.ensureLoaded();

    expect(AppFnConnectionSettings.connectionOrder.value, [
      ProbeCandidateGroup.publicIPv4,
      ProbeCandidateGroup.relay,
      ProbeCandidateGroup.internal,
      ProbeCandidateGroup.publicIPv6,
    ]);
  });

  test('garbage/duplicate entries are dropped and defaults appended', () async {
    SharedPreferences.setMockInitialValues({
      'fn_connection_order': ['garbage', 'internal', 'internal'],
    });

    await AppFnConnectionSettings.ensureLoaded();

    expect(
      AppFnConnectionSettings.connectionOrder.value,
      kDefaultConnectionOrder,
    );
  });

  test('legacy relayFirst migrates to relay-before-public order', () async {
    SharedPreferences.setMockInitialValues({
      'fn_connection_preference': 'relayFirst',
    });

    await AppFnConnectionSettings.ensureLoaded();

    expect(AppFnConnectionSettings.connectionOrder.value, [
      ProbeCandidateGroup.internal,
      ProbeCandidateGroup.relay,
      ProbeCandidateGroup.publicIPv6,
      ProbeCandidateGroup.publicIPv4,
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('fn_connection_order'), [
      'internal',
      'relay',
      'publicIPv6',
      'publicIPv4',
    ]);
    expect(prefs.getString('fn_connection_preference'), isNull);
  });

  test(
    'setConnectionOrder persists normalized list and updates notifier',
    () async {
      SharedPreferences.setMockInitialValues({});

      await AppFnConnectionSettings.ensureLoaded();

      await AppFnConnectionSettings.setConnectionOrder([
        ProbeCandidateGroup.relay,
        ProbeCandidateGroup.internal,
      ]);

      expect(AppFnConnectionSettings.connectionOrder.value, [
        ProbeCandidateGroup.relay,
        ProbeCandidateGroup.internal,
        ProbeCandidateGroup.publicIPv6,
        ProbeCandidateGroup.publicIPv4,
      ]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('fn_connection_order'), [
        'relay',
        'internal',
        'publicIPv6',
        'publicIPv4',
      ]);
    },
  );

  test('disabled groups default empty', () async {
    SharedPreferences.setMockInitialValues({});
    await AppFnConnectionSettings.ensureLoaded();
    expect(AppFnConnectionSettings.disabledGroups.value, isEmpty);
  });

  test('setGroupDisabled persists and updates notifier', () async {
    SharedPreferences.setMockInitialValues({});
    await AppFnConnectionSettings.ensureLoaded();

    await AppFnConnectionSettings.setGroupDisabled(
      ProbeCandidateGroup.relay,
      true,
    );
    expect(
      AppFnConnectionSettings.disabledGroups.value,
      contains(ProbeCandidateGroup.relay),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('fn_disabled_groups'), ['relay']);
  });

  test('setGroupDisabled re-enables removes from set and prefs', () async {
    SharedPreferences.setMockInitialValues({
      'fn_disabled_groups': ['relay', 'internal'],
    });
    await AppFnConnectionSettings.ensureLoaded();

    await AppFnConnectionSettings.setGroupDisabled(
      ProbeCandidateGroup.relay,
      false,
    );
    expect(
      AppFnConnectionSettings.disabledGroups.value,
      isNot(contains(ProbeCandidateGroup.relay)),
    );
    expect(
      AppFnConnectionSettings.disabledGroups.value,
      contains(ProbeCandidateGroup.internal),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('fn_disabled_groups'), ['internal']);
  });

  test('disabled groups survive reload (persisted)', () async {
    SharedPreferences.setMockInitialValues({
      'fn_disabled_groups': ['publicIPv4'],
    });
    await AppFnConnectionSettings.ensureLoaded();
    expect(
      AppFnConnectionSettings.disabledGroups.value,
      contains(ProbeCandidateGroup.publicIPv4),
    );

    // 模拟重启：重置懒加载后重新读
    AppFnConnectionSettings.resetForTest();
    await AppFnConnectionSettings.ensureLoaded();
    expect(
      AppFnConnectionSettings.disabledGroups.value,
      contains(ProbeCandidateGroup.publicIPv4),
    );
  });

  test('effectiveOrder removes disabled groups, keeps order', () async {
    SharedPreferences.setMockInitialValues({});
    await AppFnConnectionSettings.ensureLoaded();

    await AppFnConnectionSettings.setGroupDisabled(
      ProbeCandidateGroup.relay,
      true,
    );
    await AppFnConnectionSettings.setGroupDisabled(
      ProbeCandidateGroup.internal,
      true,
    );

    final effective = FnConnectionProbeService.effectiveOrder(
      kDefaultConnectionOrder,
    );
    expect(effective, [
      ProbeCandidateGroup.publicIPv6,
      ProbeCandidateGroup.publicIPv4,
    ]);
  });

  test('effectiveOrder no disabled groups → order unchanged', () async {
    SharedPreferences.setMockInitialValues({});
    await AppFnConnectionSettings.ensureLoaded();
    expect(
      FnConnectionProbeService.effectiveOrder(kDefaultConnectionOrder),
      kDefaultConnectionOrder,
    );
  });

  group('shouldBypassSslForHost：IP 直连恒放行、域名按开关', () {
    test('IPv4 / IPv6 字面量（含方括号）恒放行，无论开关', () {
      AppFnConnectionSettings.ignoreSsl.value = false;
      expect(
        AppFnConnectionSettings.shouldBypassSslForHost('192.168.11.200'),
        isTrue,
      );
      expect(
        AppFnConnectionSettings.shouldBypassSslForHost('10.0.0.1'),
        isTrue,
      );
      expect(
        AppFnConnectionSettings.shouldBypassSslForHost(
          '2001:db8::1',
        ),
        isTrue,
      );
      expect(
        AppFnConnectionSettings.shouldBypassSslForHost(
          '[2001:db8::1]',
        ),
        isTrue,
      );
    });

    test('域名按 ignoreSsl 开关', () {
      AppFnConnectionSettings.ignoreSsl.value = false;
      expect(
        AppFnConnectionSettings.shouldBypassSslForHost('nas.example.com'),
        isFalse,
      );
      AppFnConnectionSettings.ignoreSsl.value = true;
      expect(
        AppFnConnectionSettings.shouldBypassSslForHost('nas.example.com'),
        isTrue,
      );
      // 形似 IP 的域名（nip.io 风格）不算 IP 字面量，按域名处理
      AppFnConnectionSettings.ignoreSsl.value = false;
      expect(
        AppFnConnectionSettings.shouldBypassSslForHost('192.168.11.200.nip.io'),
        isFalse,
      );
    });
  });
}
