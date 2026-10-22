import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_connection_probe_service.dart';

/// 探测超时策略：
/// - 中继/域名候选（relayMode）连接耗时最长（设备 → 5ddd.com CDN → FN 转发），
///   探测窗口要足够容纳真可达但慢的中继，放宽到 10s；
/// - 直连 IP 候选 3s（内网/公网直连通常更快，但公网经移动网络跨网/弱网可达
///   的直连需要一定缓冲，3s 平衡「尽早失败」与「不误判慢速直连」）；
/// - 缓存/回前台校验的 connect 超时：直连 3s；中继同理放宽到 10s——
///   快探窗口对「真可达但慢」的地址会误判不可达，回退整轮全量探测（最慢）；
/// - 升级扫描（缓存可达后确认「是否有更高优先级候选」）是锦上添花，收紧到 400ms，
///   扫不到更高优先级只是留在当前缓存连接，无需每次启动都为「确认没有更好」白等。
void main() {
  group('探测超时策略', () {
    test('中继候选（relayMode）→ 10s', () {
      expect(
        fnProbeTimeout(true),
        const Duration(seconds: 10),
      );
    });

    test('直连候选（非 relayMode）→ 3s', () {
      expect(
        fnProbeTimeout(false),
        const Duration(seconds: 3),
      );
    });

    test('缓存/回前台校验 connect 超时 → 3s', () {
      expect(
        kFnCachedProbeConnectTimeout,
        const Duration(seconds: 3),
      );
    });
  });

  group('缓存/升级探测超时策略', () {
    test('缓存快探中继 → 10s（与全量中继探测同预算）', () {
      expect(
        cachedProbeTimeout(true),
        const Duration(seconds: 10),
      );
    });

    test('缓存快探直连 → 3s（kFnCachedProbeConnectTimeout）', () {
      expect(cachedProbeTimeout(false), kFnCachedProbeConnectTimeout);
      expect(cachedProbeTimeout(false), const Duration(seconds: 3));
    });

    test('升级扫描超时短于全量直连探测超时（错过只是留在缓存连接）', () {
      expect(kFnUpgradeProbeTimeout, lessThan(fnProbeTimeout(false)));
      expect(kFnUpgradeProbeTimeout, isNot(equals(Duration.zero)));
    });
  });
}
