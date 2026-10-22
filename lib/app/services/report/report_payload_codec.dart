import 'dart:convert';

/// 报告 payload 编码：base64url（无压缩），嵌入 WebView URL hash。
///
/// 报告 payload 是聚合后的有限大小（约 20-40KB），不需要压缩即可放入 URL hash，
/// 避免 Flutter/网页两端 gzip 解压库耦合（Flutter 端 dart:io gzip 默认走 deflate
/// 压缩，网页端要完整解压需要引入 pako，得不偿失）。
///
/// 与网页端（mirror/index.html）的解码逻辑对应：
/// `atob(b64url)` → JSON.parse。
class ReportPayloadCodec {
  ReportPayloadCodec._();

  /// 把报告 JSON 编码成 URL hash 可用的字符串（base64url）。
  static String encode(Map<String, dynamic> payload) {
    final json = jsonEncode(payload);
    return base64Url.encode(utf8.encode(json));
  }

  /// 解码（base64url → JSON），供测试/调试用。
  static Map<String, dynamic>? decode(String encoded) {
    try {
      final bytes = base64Url.decode(encoded);
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
