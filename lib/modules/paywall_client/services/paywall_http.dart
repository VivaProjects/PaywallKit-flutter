import '../models/paywall_http_failure.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 有界请求统一拒绝重定向，避免离开已验证的配置或页面来源。
class PaywallHttp {
  /// 限制整个响应的时间与字节数，错误响应不写入缓存。
  static Future<String> fetch(Uri uri,
      {String method = 'GET',
      String? body,
      int limit = 1000000,
      Duration timeout = const Duration(seconds: 12)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      client.close(force: true);
    });
    try {
      // 禁止自动重定向，来源信任必须由调用方显式校验。
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set('Accept', 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close();
      if (response.statusCode != 200) {
        throw PaywallHttpFailure(response.statusCode);
      }
      if (response.contentLength > limit) {
        throw const HttpException('Invalid paywall response');
      }
      // 按块限制大小，不能相信 Content-Length 一定存在或正确。
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > limit)
          throw const FormatException('Response too large');
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    } catch (_) {
      if (timedOut) throw TimeoutException('Paywall download deadline');
      rethrow;
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }
}
