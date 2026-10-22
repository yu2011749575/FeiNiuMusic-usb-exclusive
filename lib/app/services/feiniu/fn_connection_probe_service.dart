import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../state/settings_fn_state.dart';
import 'api_client.dart';
import 'fn_models.dart';

/// 从探测响应中识别「HTTP 被服务器强制跳转 HTTPS」的 3xx 重定向（如 nginx
/// `return 302 https://$host:<httpsPort>$request_uri`）。是则返回跳转目标的
/// HTTPS URL（相对 [Response.requestOptions.uri] 解析，兼容相对/协议相对
/// Location），否则返回 null。
///
/// 该场景下 HTTP 端口「TCP 可达但不可用」：dart:io HttpClient 自动跟随跨
/// 协议/跨端口重定向时会丢弃 `Cookie`（SDK `shouldCopyHeaderOnRedirect` 仅
/// 同 scheme + 同 port 才复制），封面/音频资源请求将不带 `music-token` 被
/// 服务端拒绝。因此探测应把 HTTP 候选判为不可用，让 HTTPS 候选胜出。
String? fnHttpToHttpsRedirectTarget(Response response) {
  final status = response.statusCode ?? 0;
  if (status < 300 || status >= 400) return null;
  final location = response.headers.value('location');
  if (location == null || location.isEmpty) return null;
  final uri = response.requestOptions.uri.resolve(location);
  return uri.isScheme('https') ? uri.toString() : null;
}

/// 探测响应是否为「HTTP 强制跳转 HTTPS」的重定向（见
/// [fnHttpToHttpsRedirectTarget]）。
bool fnRedirectsToHttps(Response response) =>
    fnHttpToHttpsRedirectTarget(response) != null;

/// 从「HTTP 强制跳转 HTTPS」的跳转目标中提取服务器基址（`scheme://host:port`）。
///
/// 探测 URL 是 `<服务器地址> + probePath`，nginx 的 302 Location 会原样携带该
/// 路径（如 `https://host:port/music/api/v1/track/list`）。剥掉 probePath
/// （含其上的 `/music/api/v1` 前缀）与末尾斜杠，恢复基址——否则调用方会把
/// baseUrl 当成带路径的地址，再拼 `/music/api/v1` 后打到双重路径导致 404。
///
/// [authChecked] 为 true 时探测路径是 `/music/api/v1/track/list`，需要精确
/// 剥掉该后缀；未鉴权探测根路径（probePath 为空）时无需剥。
String fnHttpsRedirectBase(String redirectTarget, {required bool authChecked}) {
  final probeSuffix = authChecked ? '/music/api/v1/track/list' : '';
  var base = redirectTarget;
  if (probeSuffix.isNotEmpty && base.endsWith(probeSuffix)) {
    base = base.substring(0, base.length - probeSuffix.length);
  }
  base = base.replaceAll(RegExp(r'/music/api/v1/*$'), '');
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

/// 探测响应是否判定候选「可用」。
///
/// [authChecked] 为 true（已登录、探测携带 token）时，候选必须通过鉴权才算
/// 可用：TCP 可达但 token 被拒的地址（HTTP 401/403、5xx，或业务码非 0 如
/// `INVALID TOKEN`）会被排除，避免探测选到「能连上但用不了」的链路（典型：
/// 当前登录凭据绑定 FNID 中继，但候选列表里有 TCP 可达的公网直连 IP——
/// 会因 token 不匹配全量 401）。未鉴权检查（登录前 TCP-only）时一律视为可用。
///
/// 例外：无论是否鉴权，**HTTP 候选若被服务器 302 强制跳转 HTTPS 一律判为
/// 不可用**（见 [fnRedirectsToHttps]）——HTTP 链路跟随重定向会丢 Cookie，
/// 资源请求必然失败，不能让探测选到它。
bool fnProbeResponseUsable(
  dynamic response, {
  required bool authChecked,
}) {
  if (response is! Response) return false;
  if (fnRedirectsToHttps(response)) return false;
  if (!authChecked) return true;
  final status = response.statusCode ?? 0;
  if (status >= 400) return false;
  final data = response.data;
  if (data is Map<String, dynamic>) {
    final code = data['code'];
    if (code is num) return code == 0;
  }
  return true;
}

/// 早停并行探测的返回结果。
///
/// - [best]：优先级最高且已确认可达的候选（[candidates] 已按优先级降序，
///   索引 0 最高）；全部不可达时为 null。
/// - [bestIndex]：[best] 在候选列表中的索引（[best] 为 null 时亦为 null）。
/// - [decided]：返回时已得出探测结论的候选结果。成功时为早停后的部分列表；
///   全部失败时等于全部候选（供调用方构建失败摘要）。
typedef ProbeBestReachableResult = ({
  ProbeCandidateResult? best,
  int? bestIndex,
  List<ProbeCandidateResult> decided,
});

/// 探测单条候选链路的超时。
///
/// 中继/域名候选（relayMode）链路最长（设备 → 5ddd.com CDN → FN 设备转发），
/// TLS 握手 + CDN 往返比直连慢，探测窗口要足够容纳「真可达但慢」的中继，
/// 放宽到 10s。直连 IP 候选 3s（内网/公网直连通常更快，但公网经移动网络跨网/
/// 弱网可达的直连需要一定缓冲，3s 平衡「尽早失败」与「不误判慢速直连」）。
Duration fnProbeTimeout(bool isRelay) =>
    isRelay ? const Duration(seconds: 10) : const Duration(seconds: 3);

/// 缓存/回前台校验（[FnConnectionProbeService.isAddressReachable] /
/// [FnConnectionProbeService.probeSmart] 缓存快探）直连缓存的 connect 超时。
/// 200ms 对「慢但可达」的地址（如空闲连接被服务端关闭后需重建 TLS 的地址）
/// 误判过激进，会误触发整轮重连；放宽到 3s。
const Duration kFnCachedProbeConnectTimeout = Duration(seconds: 3);

/// 缓存/回前台校验（[_tryCachedAddress]）的 connect 超时，按中继语义区分。
///
/// - 中继缓存（relay）链路最长（设备 → 5ddd.com CDN → FN 设备转发），
///   3s 快探窗口对「真可达但慢」的中继会误判不可达，进而回退整轮全量探测
///   （直连候选逐个等 3s 超时 + 中继 10s）——比直接放慢快探更拖时间。
///   故与全量中继探测同预算 [fnProbeTimeout]（10s）。
/// - 直连缓存保持 [kFnCachedProbeConnectTimeout]（3s）。
Duration cachedProbeTimeout(bool isRelay) =>
    isRelay ? fnProbeTimeout(true) : kFnCachedProbeConnectTimeout;

/// 缓存可达后的「升级扫描」超时（[FnConnectionProbeService.probeSmart]
/// Step 2 探测优先级更高的候选）。
///
/// 升级扫描是锦上添花：扫不到更高优先级只是留在当前缓存连接，不损失功能。
/// 收紧到 400ms，避免每次启动/重连为「确认没有更好」白白等直连候选逐个
/// 3s 超时（尤其当缓存是中继、直连候选在当下网络全不可达时）。
const Duration kFnUpgradeProbeTimeout = Duration(milliseconds: 400);

/// FN 连接探测服务（单例）
///
/// 核心职责：
/// 1. 调用 FN 接口获取连接参数
/// 2. 按优先级分层探测可用链路（直连 3 秒 / 中继 10 秒超时）
/// 3. 返回首个可用的连接地址
///
/// 探测规则：
/// - 内网 IPv4 永久最高优先级
/// - HTTPS 端口优先于 HTTP
/// - 公网优先模式探测公网 IPv6 → IPv4 → 中继
/// - 中继优先模式跳过公网直连
/// - 单链路探测超时：直连 IP 3 秒，中继/域名 10 秒（见 [fnProbeTimeout]）
class FnConnectionProbeService {
  FnConnectionProbeService._();

  static final FnConnectionProbeService instance = FnConnectionProbeService._();

  /// FN 接口签名常量
  static const String _authxPrefix = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
  static const String _apiKey = 'zIGtkc3dqZnJpd29qZXJqa2w7c';

  /// 是否正在探测中
  final ValueNotifier<bool> isProbing = ValueNotifier(false);

  /// 过滤掉已禁用分组的连接优先级顺序。
  ///
  /// 所有探测路径（probeSmart / 缓存升级 / 全量分层 / probeAllCandidates）都经
  /// [buildProbeCandidateSpecs] 构造候选，这里统一过滤，保证「禁用的分组不再
  /// 探测」在所有入口生效（启动 / 登录 / 自动重连 / 设置页手动探测）。
  ///
  /// [order] 为空时读 [AppFnConnectionSettings.connectionOrder]。保留顺序与去重。
  static List<ProbeCandidateGroup> effectiveOrder(
    List<ProbeCandidateGroup>? order,
  ) {
    final base = order ?? AppFnConnectionSettings.connectionOrder.value;
    final disabled = AppFnConnectionSettings.disabledGroups.value;
    if (disabled.isEmpty) return List.of(base);
    return [
      for (final g in base)
        if (!disabled.contains(g)) g,
    ];
  }

  /// 独立 Dio 实例，不与主 API 客户端共享配置
  final Dio _probeDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 3),
      sendTimeout: const Duration(seconds: 3),
      followRedirects: false,
    ),
  );

  CancelToken? _cancelToken;

  /// 在途连接探测（probeSmart 单飞行共用）
  ///
  /// 相同 FNID 的并发调用复用同一探测请求，避免重复探测——例如登录页自动
  /// 静默探测与用户点击登录同时发起时，只探测一次、共享同一结果。
  Future<ConnectionProbeResult>? _inflightProbe;
  String? _inflightProbeFnId;

  /// 单飞行入口：相同 FNID 的并发探测复用同一在途请求，结果共享，不重复探测。
  ///
  /// 不同 FNID 并发（理论场景：用户在登录页改了 FNID 立即再点）仍走旧的
  /// 「探测进行中」守卫，避免拿到错误 FNID 的探测结果。全量探测
  /// （[probeAllCandidates]）在途时同样拒绝新探测，避免 cancel token 被覆盖。
  Future<ConnectionProbeResult> _joinOrStartProbe({
    required String fnId,
    required Future<ConnectionProbeResult> Function() start,
  }) {
    final inflight = _inflightProbe;
    if (inflight != null) {
      if (_inflightProbeFnId == fnId) {
        return inflight; // 复用同一探测，结果共享
      }
      throw Exception('探测正在进行中，请等待完成');
    }
    if (isProbing.value) {
      throw Exception('探测正在进行中，请等待完成');
    }
    final future = start();
    // 探测完成（成功或失败）后自动清空在途标记，下一次可正常发起
    final tracked = future.whenComplete(_clearInflightProbe);
    _inflightProbe = tracked;
    _inflightProbeFnId = fnId;
    return tracked;
  }

  void _clearInflightProbe() {
    _inflightProbe = null;
    _inflightProbeFnId = null;
  }

  @visibleForTesting
  void resetForTest() {
    _inflightProbe = null;
    _inflightProbeFnId = null;
    _cancelToken = null;
    isProbing.value = false;
  }

  @visibleForTesting
  Future<ConnectionProbeResult> joinOrStartProbeForTest({
    required String fnId,
    required Future<ConnectionProbeResult> Function() start,
  }) {
    return _joinOrStartProbe(fnId: fnId, start: start);
  }

  /// 取消当前探测
  void cancel() {
    _cancelToken?.cancel();
  }

  /// 缓存优先探测（仅升级，不降级）
  ///
  /// 下次打开优先验证上次成功连接的 URL 是否仍可用（[kFnCachedProbeConnectTimeout] 快探）：
  /// - 缓存可达：仅探测优先级高于缓存的候选，若更高优先级链路可达则自动切换（升级）；
  ///   否则保持缓存连接（不降级）。
  /// - 缓存不可达或已不在当前候选列表（陈旧地址）：回退到完整分层探测。
  ///
  /// [cachedUrl] - 上次成功连接的 URL（来自 AppFnConnectionSettings）
  /// [cachedIsRelay] - 上次连接是否为中继模式
  /// [fnId] - FNID
  /// [order] - 连接优先级顺序，默认读 [AppFnConnectionSettings.connectionOrder]
  ///
  /// 返回 [ConnectionProbeResult]，包含最终成功的 URL。
  /// 所有链路失败时抛出 [Exception]。
  Future<ConnectionProbeResult> probeSmart({
    required String fnId,
    String? cachedUrl,
    bool cachedIsRelay = false,
    List<ProbeCandidateGroup>? order,
  }) {
    return _joinOrStartProbe(
      fnId: fnId,
      start: () => _probeSmartCore(
        fnId: fnId,
        cachedUrl: cachedUrl,
        cachedIsRelay: cachedIsRelay,
        order: order,
      ),
    );
  }

  /// 缓存优先探测核心实现（被 [probeSmart] 调用，受单飞行守卫）
  Future<ConnectionProbeResult> _probeSmartCore({
    required String fnId,
    String? cachedUrl,
    bool cachedIsRelay = false,
    List<ProbeCandidateGroup>? order,
  }) async {
    final effOrder = effectiveOrder(
      order ?? AppFnConnectionSettings.connectionOrder.value,
    );

    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      if (kDebugMode) {
        debugPrint('[FnProbe] Trying cached connection: $cachedUrl');
      }

      // Step 1: 获取参数并构建按优先级排序的候选列表
      final params = await _callFnConnectionApi(fnId, _cancelToken!);
      final candidates = buildProbeCandidateSpecs(
        fnId: fnId,
        params: params,
        order: effOrder,
      );

      // Step 2: 缓存优先快探
      if (cachedUrl != null && cachedUrl.isNotEmpty) {
        final cachedIndex = candidates.indexWhere(
          (c) => c.address == cachedUrl,
        );
        if (cachedIndex >= 0) {
          final cacheOk = await _tryCachedAddress(
            cachedUrl,
            cachedIsRelay,
            _cancelToken!,
          );
          if (cacheOk) {
            if (_cancelToken!.isCancelled) throw Exception('探测已取消');

            // 探测优先级更高的候选（索引 < cachedIndex），首个可达者即升级。
            // 升级是锦上添花：扫不到更高优先级只是留在当前缓存连接，故收紧
            // 超时（kFnUpgradeProbeTimeout）避免为「确认没有更好」白等直连候选
            // 逐个 3s 超时（缓存为中继、直连全不可达时尤其慢）。
            final better = candidates.sublist(0, cachedIndex);
            if (better.isNotEmpty) {
              final ProbeBestReachableResult upgrade =
                  await _probeBestReachable(
                    better,
                    _cancelToken!,
                    timeoutOverride: (_) => kFnUpgradeProbeTimeout,
                  );
              if (upgrade.best != null) {
                if (kDebugMode) {
                  debugPrint(
                    '[FnProbe] ✓ Upgraded (priority ${upgrade.bestIndex! + 1}): '
                    '${upgrade.best!.description}',
                  );
                }
                return ConnectionProbeResult(
                  serverUrl: upgrade.best!.address,
                  probeMethod: upgrade.best!.description,
                  isRelay: upgrade.best!.isRelay,
                );
              }
            }

            // 无更高优先级可达，保持缓存连接
            if (kDebugMode) {
              debugPrint('[FnProbe] Cached connection still valid: $cachedUrl');
            }
            return ConnectionProbeResult(
              serverUrl: cachedUrl,
              probeMethod: '缓存连接',
              isRelay: cachedIsRelay,
            );
          }
          // 缓存不可达 → 回退完整探测
        }
        // 缓存不在当前候选列表（陈旧地址）→ 忽略缓存，完整探测
      }

      // Step 3: 完整分层探测
      final result = await _hierarchicalProbe(
        fnId,
        params,
        cancelToken: _cancelToken!,
        order: effOrder,
      );

      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Full probe succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }
      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
      _clearInflightProbe();
    }
  }

  /// 快速验证某个地址是否可达（[kFnCachedProbeConnectTimeout] 快探）。
  ///
  /// 供自动重连的「App 回到前台」一次性校验使用：不触发完整探测，不发
  /// FN API，只探测指定 URL 的连通性。被其他探测占用（isProbing）时返回
  /// null，调用方按"可达"处理跳过本次；不可达返回 false。
  Future<bool?> isAddressReachable(String url, {bool isRelay = false}) async {
    if (isProbing.value) return null;
    isProbing.value = true;
    _cancelToken = CancelToken();
    try {
      return await _tryCachedAddress(url, isRelay, _cancelToken!);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return null;
      }
      return false;
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  /// 探测单条候选地址，返回「实际应使用的连接地址」：
  ///
  /// - 候选可用（[fnProbeResponseUsable] 通过）→ 原样返回候选；
  /// - 候选为 HTTP 且服务器 302 强制跳转 HTTPS → 返回跳转后的 HTTPS URL
  ///   （端口取自服务器 Location，适配自定义端口/自定义 scheme）；
  /// - 其余失败（连接错误 / 超时 / 被其它探测占用）→ 返回 null。
  ///
  /// 供登录页手动填写服务器地址时使用：用户填 `http://ip:5666`，服务器开启了
  /// 「HTTP 强制跳转 HTTPS」时直接改用 `https://ip:5667` 登录，避免 App 留在
  /// HTTP 后封面/音频因重定向丢 Cookie 全部加载失败。
  Future<String?> probeEffectiveUrl(
    String url, {
    bool isRelay = false,
  }) async {
    if (isProbing.value) return null;
    isProbing.value = true;
    _cancelToken = CancelToken();
    try {
      return await _probeEffectiveUrl(url, isRelay, _cancelToken!);
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  Future<String?> _probeEffectiveUrl(
    String url,
    bool isRelay,
    CancelToken cancelToken,
  ) async {
    final start = DateTime.now();
    final token = FeiNiuApiClient.instance.token;
    final authChecked = token.isNotEmpty;
    try {
      final probePath = authChecked ? '/music/api/v1/track/list' : '';
      final response = await _probeDio.getUri(
        Uri.parse(url + probePath),
        cancelToken: cancelToken,
        options: Options(
          connectTimeout: cachedProbeTimeout(isRelay),
          receiveTimeout: const Duration(seconds: 1),
          sendTimeout: const Duration(seconds: 1),
          followRedirects: false,
          validateStatus: (_) => true,
          // 鉴权与中继合并进同一个 Cookie 头，避免拆成两个键互相覆盖丢 mode=relay。
          headers: {
            if (authChecked)
              'Cookie': isRelay
                  ? 'music-token=$token; mode=relay'
                  : 'music-token=$token'
            else if (isRelay)
              'Cookie': 'mode=relay',
          },
        ),
      );
      if (fnProbeResponseUsable(response, authChecked: authChecked)) {
        return url;
      }
      // HTTP 候选被服务器强制跳转 HTTPS → 返回跳转目标，让调用方直接连 HTTPS。
      final redirectTarget = fnHttpToHttpsRedirectTarget(response);
      if (redirectTarget != null) {
        // 探测 URL 是 <服务器地址> + probePath；nginx 的 302 Location 会原样
        // 携带该路径。fnHttpsRedirectBase 剥掉 probePath（含 /music/api/v1
        // 前缀）与末尾斜杠，恢复 scheme://host:port 基址（与 FNID 探测保存的
        // URL 形态一致），否则登录会打到双重路径 → 404 登录失败。
        final base = fnHttpsRedirectBase(
          redirectTarget,
          authChecked: authChecked,
        );
        if (kDebugMode) {
          debugPrint(
            '[FnProbe] $url upgraded to HTTPS ($base) in '
            '${DateTime.now().difference(start).inMilliseconds}ms',
          );
        }
        return base;
      }
      return null;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return null;
      }
      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Probe effective FAILED $url in '
          '${DateTime.now().difference(start).inMilliseconds}ms: '
          '${_dioErrorMessage(e)}',
        );
      }
      return null;
    }
  }

  /// 直连 IP（非 FNID）HTTP 连接的 HTTPS 保活升级。
  ///
  /// 探测当前活动 baseUrl，服务器「HTTP 强制跳转 HTTPS」时把**内存中的活动
  /// 连接**升级为 HTTPS（[FeiNiuApiClient.setBaseUrl]，不持久化）——账号条目
  /// 与 `feiniu_server_url` 保持用户填写的地址，从而 HTTP/HTTPS 可各自存为
  /// 独立账号、互不覆盖；每次启动（预热）与账号切换时重新升级活动连接。
  /// fire-and-forget，失败静默（登录后仍可用原连接）。
  Future<void> upgradeLiveConnectionToHttpsIfRedirects() async {
    final base = FeiNiuApiClient.instance.baseUrl;
    if (base.isEmpty || base.startsWith('https://')) return;
    final token = FeiNiuApiClient.instance.token;
    if (token.isEmpty) return;
    try {
      final effective = await probeEffectiveUrl(base, isRelay: false);
      if (effective == null || effective == base) return;
      await FeiNiuApiClient.instance.setBaseUrl(effective);
      debugPrint('[FnProbe] Direct-IP HTTP connection upgraded to $effective');
    } catch (_) {
      // 升级失败静默：连接仍走原地址（重定向/错误由既有逻辑兜底）
    }
  }

  /// 快速验证缓存连接是否可达（[cachedProbeTimeout] 快探）
  Future<bool> _tryCachedAddress(
    String url,
    bool isRelay,
    CancelToken cancelToken,
  ) async {
    final start = DateTime.now();
    final token = FeiNiuApiClient.instance.token;
    final authChecked = token.isNotEmpty;
    try {
      // 已登录时缓存校验也打鉴权接口：TCP 可达但 token 被拒（INVALID TOKEN）
      // 的缓存地址应视为失效回退重探，而不是「Cached connection still valid」。
      final probePath = authChecked ? '/music/api/v1/track/list' : '';
      final response = await _probeDio.getUri(
        Uri.parse(url + probePath),
        cancelToken: cancelToken,
        options: Options(
          connectTimeout: cachedProbeTimeout(isRelay),
          receiveTimeout: const Duration(seconds: 1),
          sendTimeout: const Duration(seconds: 1),
          followRedirects: false,
          validateStatus: (_) => true,
          // 鉴权与中继合并进同一个 Cookie 头，避免拆成两个键互相覆盖丢 mode=relay。
          headers: {
            if (authChecked)
              'Cookie': isRelay
                  ? 'music-token=$token; mode=relay'
                  : 'music-token=$token'
            else if (isRelay)
              'Cookie': 'mode=relay',
          },
        ),
      );
      if (!fnProbeResponseUsable(response, authChecked: authChecked)) {
        if (kDebugMode) {
          final redirectTarget = fnHttpToHttpsRedirectTarget(response);
          debugPrint(
            '[FnProbe] Cached check REJECTED $url in '
            '${DateTime.now().difference(start).inMilliseconds}ms '
            '(status ${response.statusCode}): '
            '${redirectTarget != null ? '强制跳转 HTTPS ($redirectTarget)' : 'token 未被该地址接受'}',
          );
        }
        return false;
      }
      return true;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Cached check FAILED $url in '
          '${DateTime.now().difference(start).inMilliseconds}ms: '
          '${_dioErrorMessage(e)}',
        );
      }
      return false;
    }
  }

  /// 调用 FN 接口获取连接参数
  Future<FnConnectionParams> _callFnConnectionApi(
    String fnId,
    CancelToken cancelToken,
  ) async {
    const apiPath = '/api/v1/fn/con';
    final url = 'https://5ddd.com$apiPath';
    final data = {'fnId': fnId};

    final response = await _probeDio.post(
      url,
      data: data,
      cancelToken: cancelToken,
      options: Options(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {'authx': _computeAuthx('post', apiPath, data)},
      ),
    );

    final parsed = FnConnectionResponse.fromJson(
      response.data as Map<String, dynamic>,
    );

    if (!parsed.isSuccess || parsed.data == null) {
      throw Exception(parsed.msg.isNotEmpty ? parsed.msg : 'FNID 查询失败，请检查输入');
    }

    return parsed.data!;
  }

  /// 计算 authx 签名请求头
  ///
  /// 注意：url 参数必须传相对路径（如 /api/v1/fn/con），
  /// 服务端签名校验用的是路径部分，不是完整 URL。
  ///
  /// 算法：
  ///   raw = PREFIX + url + nonce + timestamp + md5(参数) + apiKey
  ///   sign = md5(raw)
  ///   authx = nonce=xxx&timestamp=xxx&sign=xxx
  static String _computeAuthx(String method, String url, dynamic data) {
    final c = method == 'get'
        ? _sortAndSerializeQuery(data as Map<String, dynamic>?)
        : jsonEncode(data);
    final nonce = (Random().nextInt(900000) + 100000).toString().padLeft(
      6,
      '0',
    );
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final raw = [
      _authxPrefix,
      url,
      nonce,
      timestamp,
      _md5(c),
      _apiKey,
    ].join('_');
    final sign = _md5(raw);
    return 'nonce=$nonce&timestamp=$timestamp&sign=$sign';
  }

  static String _md5(String input) {
    return crypto.md5.convert(utf8.encode(input)).toString();
  }

  static String _sortAndSerializeQuery(Map<String, dynamic>? params) {
    if (params == null || params.isEmpty) return '';
    final keys = params.keys.toList()..sort();
    return keys
        .map((k) => '$k=${Uri.encodeComponent(params[k].toString())}')
        .join('&');
  }

  /// 探测所有候选链路（用于「FN Connect」设置页完整展示）
  ///
  /// 与 [probe] 不同，此方法会探测*所有*候选地址并返回完整结果列表，
  /// 同时返回首个可用连接。
  ///
  /// 返回一个元组：(所有候选结果列表, 首个成功的 [ConnectionProbeResult] 或 null)
  Future<
    ({
      List<ProbeCandidateResult> candidates,
      ConnectionProbeResult? firstSuccess,
    })
  >
  probeAllCandidates({
    required String fnId,
    List<ProbeCandidateGroup>? order,
  }) async {
    if (isProbing.value) {
      throw Exception('探测正在进行中，请等待完成');
    }

    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      final params = await _callFnConnectionApi(fnId, _cancelToken!);
      final candidates = buildProbeCandidateSpecs(
        fnId: fnId,
        params: params,
        order: effectiveOrder(
          order ?? AppFnConnectionSettings.connectionOrder.value,
        ),
      );

      // 并行探测所有候选（默认所有候选中继模式共 4 条以上，并行可加速）
      final results = await Future.wait(
        candidates.map((c) => _tryAddressWithDetail(c, _cancelToken!)),
      );

      final firstSuccess = results
          .where((r) => r.isReachable)
          .map(
            (r) => ConnectionProbeResult(
              serverUrl: r.address,
              probeMethod: r.description,
              isRelay: r.isRelay,
            ),
          )
          .firstOrNull;

      return (candidates: results, firstSuccess: firstSuccess);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  /// 并发探测所有候选，按优先级取「首个已确认可达」的链路，支持早停。
  ///
  /// [candidates] 须已按优先级降序排列（索引 0 为最高优先级）。返回
  /// [ProbeBestReachableResult]：
  /// - [ProbeBestReachableResult.best] 为优先级最高且已确认可达的候选；
  ///   全部不可达时为 null。
  /// - [ProbeBestReachableResult.decided] 为返回时已得出结论的候选结果：
  ///   成功时为早停后的部分列表；全部失败时等于全部候选（供调用方构建中文
  ///   失败摘要）。
  ///
  /// 不变量：
  /// 1. 不牺牲优先级：仍有更高优先级候选未出结果时绝不返回（`Future.any`
  ///    按完成序处理，配合 [bestIndex] 只在确认无更优后才早停）。
  /// 2. 不慢于全量等待：返回时刻 ≤ 所有候选探测完成时刻。
  /// 3. 取消优先：任一探测以 cancel 失败（[DioException] 穿透）或 token
  ///    已取消时，立即向上传播，由调用方映射为 `Exception('探测已取消')`。
  Future<ProbeBestReachableResult> _probeBestReachable(
    List<ProbeCandidateSpec> candidates,
    CancelToken cancelToken, {
    Future<ProbeCandidateResult> Function(ProbeCandidateSpec, CancelToken)?
        probe,
    Duration Function(bool isRelay)? timeoutOverride,
  }) async {
    final pickTimeout = timeoutOverride ?? fnProbeTimeout;
    // 未注入 probe 时走默认探测，并把超时策略透传给 _tryAddressWithDetail
    // （默认 fnProbeTimeout；升级扫描注入 kFnUpgradeProbeTimeout）。
    final doProbe = probe ??
        (ProbeCandidateSpec c, CancelToken token) =>
            _tryAddressWithDetail(c, token, timeoutOverride: pickTimeout);
    if (candidates.isEmpty) {
      final ProbeBestReachableResult empty = (
        best: null,
        bestIndex: null,
        decided: <ProbeCandidateResult>[],
      );
      return empty;
    }

    // 每个候选的探测 future 携带自身索引（记录），Future.any 直接返回
    // (idx, result)，无需 identity 反查。
    final pending = <int, Future<(int, ProbeCandidateResult)>>{
      for (var i = 0; i < candidates.length; i++)
        i: doProbe(candidates[i], cancelToken).then((r) => (i, r)),
    };

    ProbeCandidateResult? best;
    int? bestIndex;
    final decided = <ProbeCandidateResult>[];

    while (pending.isNotEmpty) {
      final (idx, r) = await Future.any(pending.values);
      pending.remove(idx);
      decided.add(r);

      if (cancelToken.isCancelled) throw Exception('探测已取消');

      if (r.isReachable) {
        if (bestIndex == null || idx < bestIndex) {
          bestIndex = idx;
          best = r;
        }
      }
      // 早停：已有确认可达者，且不存在仍未决定（索引更小）的更高优先级
      // 候选 —— 无论本次结果是可达还是不可达都检查：更高优先级候选确认
      // 不可达后，同样可能满足早停条件（无需再等更低优先级）。
      final noBetterPending = bestIndex != null &&
          (bestIndex == 0 || !pending.keys.any((i) => i < bestIndex!));
      if (noBetterPending) {
        if (cancelToken.isCancelled) throw Exception('探测已取消');
        return (best: best, bestIndex: bestIndex, decided: decided);
      }
    }

    return (best: best, bestIndex: bestIndex, decided: decided);
  }

  /// 测试专用：注入逐候选探测函数，确定性复现「早停 + 优先级」竞态。
  ///
  /// 生产代码走 [_probeBestReachable] 默认的 [_tryAddressWithDetail]。
  @visibleForTesting
  Future<ProbeBestReachableResult> probeBestReachableForTest({
    required List<ProbeCandidateSpec> candidates,
    required CancelToken cancelToken,
    required Future<ProbeCandidateResult> Function(
      ProbeCandidateSpec,
      CancelToken,
    )
    probe,
  }) {
    return _probeBestReachable(candidates, cancelToken, probe: probe);
  }

  /// 并发探测所有候选地址，按优先级取首个可用
  Future<ConnectionProbeResult> _hierarchicalProbe(
    String fnId,
    FnConnectionParams params, {
    required CancelToken cancelToken,
    required List<ProbeCandidateGroup> order,
  }) async {
    final candidates = buildProbeCandidateSpecs(
      fnId: fnId,
      params: params,
      order: effectiveOrder(order),
    );

    final ProbeBestReachableResult probeResult =
        await _probeBestReachable(candidates, cancelToken);

    final best = probeResult.best;
    if (best != null) {
      if (kDebugMode) {
        debugPrint(
          '[FnProbe] ✓ Success (priority ${probeResult.bestIndex! + 1}): '
          '${best.description}',
        );
      }
      return ConnectionProbeResult(
        serverUrl: best.address,
        probeMethod: best.description,
        isRelay: best.isRelay,
      );
    }

    // 全部失败：用 decided（= 全部候选，因全部失败时不会早停）收集去重后的
    // 失败原因，帮助用户定位（如「端口不通」）。设置页会逐条展示；这里的摘要
    // 让登录 / 自动重连的异常也能看到关键信息。error 形如「连接失败：连接被
    // 拒绝（端口不通或服务未启动）」，摘要里已说「所有链路均无法连接」，再去掉
    // 「连接失败：」前缀避免语义重复。
    final reasons = <String>[
      for (final r in probeResult.decided)
        if (!r.isReachable && r.error != null && r.error!.isNotEmpty)
          r.error!.replaceFirst(RegExp(r'^连接失败：'), ''),
    ];
    final distinct = reasons.toSet().toList();
    final detail = distinct.length <= 2
        ? distinct.join('；')
        : '${distinct.take(2).join('；')} 等 ${distinct.length} 种原因';
    final summary = detail.isNotEmpty
        ? '所有链路均无法连接：$detail。请检查网络、端口或稍后重试。'
        : '所有链路均无法连接，请检查网络或稍后重试。';
    throw Exception(summary);
  }

  /// 探测单条链路并返回探测结果详情
  Future<ProbeCandidateResult> _tryAddressWithDetail(
    ProbeCandidateSpec candidate,
    CancelToken cancelToken, {
    Duration Function(bool isRelay)? timeoutOverride,
  }) async {
    // 中继/域名候选链路更长（CDN 转发 + TLS 重建），放宽超时避免误判
    final timeout = (timeoutOverride ?? fnProbeTimeout)(candidate.relayMode);
    final start = DateTime.now();
    // 已登录时探测携带当前 token：候选须通过鉴权才算「可用」，排除 TCP 可达
    // 但 token 被拒的链路（如与当前登录凭据不匹配的服务器 IP → INVALID TOKEN）。
    final token = FeiNiuApiClient.instance.token;
    final authChecked = token.isNotEmpty;
    try {
      final options = Options(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        followRedirects: false,
        validateStatus: (_) => true,
        // 注意：中继与鉴权都要走 Cookie，且 relay 必须带上 mode=relay，
        // 不能拆成两个 'Cookie' 键（map 字面量后者覆盖前者）——
        // 否则中继链路鉴权会丢 mode=relay 被服务器误判。
        headers: {
          if (authChecked)
            'Cookie': candidate.relayMode
                ? 'music-token=$token; mode=relay'
                : 'music-token=$token'
          else if (candidate.relayMode)
            'Cookie': 'mode=relay',
        },
      );

      // 已登录：打一个轻量鉴权接口（track/list 不产生副作用）验证 token 是否
      // 被该地址接受；未登录则探测根路径（仅 TCP 可达性）。
      final probePath = authChecked ? '/music/api/v1/track/list' : '';
      final response = await _probeDio.getUri(
        Uri.parse(candidate.address + probePath),
        options: options,
        cancelToken: cancelToken,
      );

      if (!fnProbeResponseUsable(response, authChecked: authChecked)) {
        // HTTP 被服务器强制跳转 HTTPS：HTTP 链路跟随重定向会丢 Cookie，
        // 资源请求必然失败，给出明确文案（区别于「token 未被接受」）。
        final redirectTarget = fnHttpToHttpsRedirectTarget(response);
        if (kDebugMode) {
          debugPrint(
            '[FnProbe] Probe REJECTED ${candidate.description} in '
            '${DateTime.now().difference(start).inMilliseconds}ms '
            '(status ${response.statusCode}): '
            '${redirectTarget != null ? '强制跳转 HTTPS ($redirectTarget)' : 'token 未被该地址接受'}',
          );
        }
        return ProbeCandidateResult(
          address: candidate.address,
          description: candidate.description,
          group: candidate.group,
          ipLabel: candidate.ipLabel,
          isRelay: candidate.relayMode,
          isReachable: false,
          error: redirectTarget != null
              ? '服务器强制跳转 HTTPS，HTTP 端口不可直连'
              : '连接可用但登录校验失败（token 未被该地址接受）',
        );
      }

      return ProbeCandidateResult(
        address: candidate.address,
        description: candidate.description,
        group: candidate.group,
        ipLabel: candidate.ipLabel,
        isRelay: candidate.relayMode,
        isReachable: true,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Probe FAILED ${candidate.description} in '
          '${DateTime.now().difference(start).inMilliseconds}ms: '
          '${_dioErrorMessage(e)}',
        );
      }
      return ProbeCandidateResult(
        address: candidate.address,
        description: candidate.description,
        group: candidate.group,
        ipLabel: candidate.ipLabel,
        isRelay: candidate.relayMode,
        isReachable: false,
        error: _dioErrorMessage(e),
      );
    }
  }

  /// 把 [DioException] 映射为可读的中文错误描述。
  ///
  /// [target] 可选：探测目标地址（如 `http://192.168.11.200:5666`）。仅在没有
  /// 其它上下文展示地址时才传（如登录页全量失败摘要），设置页候选链路不传——
  /// 该页的标题已含 IP 与端口，再附会重复。
  String _dioErrorMessage(DioException e, {String? target}) {
    final targetPart =
        (target != null && target.isNotEmpty) ? '（$target）' : '';
    // 底层已解析出具体原因（如「连接被拒绝（端口不通或服务未启动）」
    // 「连接超时（端口无响应）」）时，直接作为完整文案返回，不再前置
    // 「连接失败」「连接超时」等类型词，避免「连接失败：连接被拒绝…」这类重复。
    // badResponse / badCertificate / cancel 属于 HTTP/协议层，走各自专属文案。
    final detail = _extractConnectionDetail(e);
    if (detail.isNotEmpty) {
      switch (e.type) {
        case DioExceptionType.badResponse:
        case DioExceptionType.badCertificate:
        case DioExceptionType.cancel:
          break;
        default:
          return '$targetPart$detail';
      }
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时$targetPart';
      case DioExceptionType.receiveTimeout:
        return '响应超时$targetPart';
      case DioExceptionType.sendTimeout:
        return '发送超时$targetPart';
      case DioExceptionType.connectionError:
        return '连接失败$targetPart';
      case DioExceptionType.badResponse:
        return '服务器返回错误 (${e.response?.statusCode})$targetPart';
      case DioExceptionType.badCertificate:
        return '证书校验失败$targetPart';
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        return e.message ?? '未知网络错误';
    }
  }

  /// 从 [DioException] 提取底层连接错误的具体原因（端口/拒绝/超时/DNS/TLS）。
  ///
  /// 优先用 [DioException.error]（通常是 [io.SocketException]，其 toString 含
  /// "Connection refused" / errno / address / port），否则回退解析 dio 封装的
  /// [DioException.message]。无更具体信息时返回空串（调用方不追加）。
  String _extractConnectionDetail(DioException e) {
    if (e.error != null) {
      final detail = _describeConnectionError(e.error!);
      if (detail.isNotEmpty) return detail;
    }
    final msg = e.message ?? '';
    if (msg.isNotEmpty) {
      final detail = _describeConnectionError(msg);
      if (detail.isNotEmpty) return detail;
    }
    return '';
  }

  /// 识别单个错误对象/文本描述的具体连接失败原因。
  String _describeConnectionError(Object err) {
    final text = err.toString();
    final lower = text.toLowerCase();
    if (lower.contains('connection refused') ||
        lower.contains('econnrefused') ||
        lower.contains('10061')) {
      return '连接被拒绝（端口不通或服务未启动）';
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return '连接超时（端口无响应）';
    }
    if (lower.contains('network is unreachable') ||
        lower.contains('network unreachable') ||
        lower.contains('ehostunreach') ||
        lower.contains('enetunreach')) {
      return '网络不可达（目标主机不在当前网络）';
    }
    if (lower.contains('host not found') ||
        lower.contains('cannot resolve') ||
        lower.contains('failed to resolve') ||
        lower.contains('name or service not known')) {
      return '无法解析主机（DNS）';
    }
    if (lower.contains('handshake') || lower.contains('certificate')) {
      return 'TLS 握手失败（证书或 HTTPS 端口异常）';
    }
    return '';
  }
}
