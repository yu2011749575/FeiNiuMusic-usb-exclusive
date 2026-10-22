import 'package:flutter/foundation.dart';

/// 听歌报告网页端配置。
///
/// 网页端是一个独立的 Cloudflare Pages 静态站点（hash 注入报告数据）。
/// - **dev 模式**（kDebugMode）：指向内网调试服务，URL 带版本参数 + 报告页清缓存，
///   保证每次加载最新网页。
/// - **正式模式**（release）：指向 Cloudflare Pages，走正常缓存（性能优先）。
class ReportWebConfig {
  ReportWebConfig._();

  /// 正式部署地址。
  static const String releaseBaseUrl = 'https://feiniu-report.pages.dev';

  /// 本地测试（内网）地址。
  static const String devBaseUrl = 'https://192.168.11.128:8786';

  /// 网页端版本号：改网页逻辑后递增，dev 模式用它绕过 CDN/WebView 缓存。
  static const String webVersion = '20260807-v2';

  /// 当前报告网页根地址（按 dev/正式环境选择）。
  static String get reportBaseUrl => kDebugMode ? devBaseUrl : releaseBaseUrl;

  /// 打开报告时的完整 URL。
  ///
  /// payload 不再拼进 URL hash（base64 内嵌图会撑爆 WebView 2MB URL 上限），
  /// 改由 App 在页面加载后经 JS 注入（见 `listening_report_page.dart`）。
  /// 这里只返回干净的页面地址，URL 恒为几十字节。
  static String buildUrl([String? _]) {
    final cacheBust = kDebugMode ? '&v=$webVersion' : '';
    return '$reportBaseUrl/?dev=1&animate=1$cacheBust';
  }
}
