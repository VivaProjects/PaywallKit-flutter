import 'dart:io';
import 'dart:convert';

import '../../paywall_renderer/models/paywall_catalog.dart';

/// H5 页面清单；宿主来源和商品目录决定可用边界。
class WebPaywallDocument {
  WebPaywallDocument._(this.documentId, this.pageUri, this.catalogKey,
      this.productRefs, this.initialProductRef, this.revision,
      [this.localDirectory]);

  final Directory? localDirectory;
  final int revision;
  final String documentId;
  final Uri pageUri;
  final String catalogKey;
  final List<String> productRefs;
  final String initialProductRef;

  /// 仅供完整包校验后的仓库绑定本地目录，远端身份仍用于缓存与商品匹配。
  WebPaywallDocument withLocalDirectory(Directory directory) =>
      WebPaywallDocument._(documentId, pageUri, catalogKey, productRefs,
          initialProductRef, revision, directory);

  /// 宿主可按当前商店地区收窄已校验清单，不能加入清单外商品。
  WebPaywallDocument selectingProductRefs(List<String> references) {
    if (references.isEmpty ||
        references.toSet().length != references.length ||
        references.any((reference) => !productRefs.contains(reference))) {
      throw const FormatException('Invalid selected web paywall products');
    }
    return WebPaywallDocument._(
        documentId,
        pageUri,
        catalogKey,
        List<String>.unmodifiable(references),
        references.first,
        revision,
        localDirectory);
  }

  /// 统一验证页面来源与商店绑定；HTTP 仅供高层显式允许的本地测试。
  static WebPaywallDocument parse(Map<String, dynamic> data,
      {required Set<String>? allowedOrigins,
      required PaywallCatalog catalog,
      String? developmentHTTPOrigin}) {
    final uri = Uri.tryParse(data['pageUrl'] is String ? data['pageUrl'] : '');
    final refs = data['productRefs'];
    final documentId = data['documentId'];
    final catalogKey = data['catalogKey'];
    final initial = data['initialProductRef'];
    const keys = {
      'kind',
      'bridgeVersion',
      'documentId',
      'revision',
      'pageUrl',
      'catalogKey',
      'productRefs',
      'initialProductRef'
    };
    if (jsonEncode(data).length > 256000 ||
        data.keys.toSet().difference(keys).isNotEmpty ||
        data.keys.length != keys.length ||
        data['kind'] != 'web-paywall' ||
        data['bridgeVersion'] != 2 ||
        data['revision'] is! int ||
        data['revision'] < 1 ||
        documentId is! String ||
        documentId.isEmpty ||
        catalogKey is! String ||
        catalogKey.isEmpty ||
        uri == null ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                !const bool.fromEnvironment('dart.vm.product') &&
                !const bool.fromEnvironment('dart.vm.profile') &&
                uri.origin == developmentHTTPOrigin)) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery ||
        (allowedOrigins != null && !allowedOrigins.contains(uri.origin)) ||
        refs is! List ||
        refs.isEmpty ||
        refs.any((ref) => ref is! String) ||
        refs.toSet().length != refs.length ||
        refs.any((ref) => !catalog.productRefs.contains(ref)) ||
        initial is! String ||
        !refs.contains(initial)) {
      throw const FormatException('Invalid web paywall document');
    }
    return WebPaywallDocument._(
        documentId,
        uri,
        catalogKey,
        List<String>.unmodifiable(refs.cast<String>()),
        initial,
        data['revision']);
  }
}
