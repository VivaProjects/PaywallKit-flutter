import 'dart:convert';
import '../models/web_paywall_resource_lease.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../paywall_client/services/paywall_http.dart';
import '../models/web_paywall_document.dart';
import '../models/web_paywall_package.dart';
import 'web_paywall_resource_cache.dart';

/// 查询响应只指定页面地址，商品绑定必须从该页面的完整发布包读取。
class WebPaywallPackageLoader {
  WebPaywallPackageLoader(
      {WebPaywallResourceCache? resourceCache, this.fetch, this.onPrepared})
      : resourceCache = resourceCache ?? WebPaywallResourceCache.shared;
  final WebPaywallResourceCache resourceCache;
  final Future<String> Function(Uri)? fetch;
  // 回调接管租约；默认调用路径仍在返回前释放。
  final void Function(WebPaywallDocument, WebPaywallResourceLease)? onPrepared;

  /// 校验来源、环境清单及全部资源后返回远端身份，无接管回调时释放临时租约。
  Future<WebPaywallDocument> load(Uri uri,
      {required String environment,
      required Set<String>? allowedOrigins,
      required PaywallCatalog catalog,
      String? developmentHTTPOrigin}) async {
    final localOrigin = environment == 'test' &&
            !const bool.fromEnvironment('dart.vm.product') &&
            !const bool.fromEnvironment('dart.vm.profile')
        ? developmentHTTPOrigin
        : null;
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.lastOrNull != 'index.html' ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && uri.origin == localOrigin)) ||
        (allowedOrigins != null && !allowedOrigins.contains(uri.origin))) {
      throw const FormatException('Invalid package URL');
    }
    // 先读取发布身份，再由缓存仓库下载并逐文件校验摘要。
    final metadataUri = uri.resolve('package.json');
    final raw = await (fetch?.call(metadataUri) ??
        PaywallHttp.fetch(metadataUri, limit: 256000));
    if (utf8.encode(raw).length > 256000)
      throw const FormatException('Package too large');
    final manifest = jsonDecode(raw) as Map<String, dynamic>;
    final payload = {
      ...WebPaywallPackage.documentForEnvironment(manifest, environment),
      'pageUrl': uri.toString()
    };
    final document = WebPaywallDocument.parse(payload,
        allowedOrigins: allowedOrigins,
        catalog: catalog,
        developmentHTTPOrigin: localOrigin);
    WebPaywallPackage.parse(utf8.encode(raw), payload, environment);
    final lease = await resourceCache.prepare(document, environment,
        timeout: const Duration(seconds: 120), manifestBytes: utf8.encode(raw));
    try {
      onPrepared?.call(document, lease);
    } catch (_) {
      lease.release();
      rethrow;
    }
    if (onPrepared == null) lease.release();
    return document;
  }
}
