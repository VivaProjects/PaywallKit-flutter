import 'dart:convert';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/services/web_paywall_package_loader.dart';
import '../models/paywall_configuration_request.dart';

/// 将业务查询接口转换成两端共用配置，坏页面只影响对应点位。
class PaywallQueryResponse {
  PaywallQueryResponse(
      {required Map<String, String> placements,
      required this.allowedOrigins,
      required this.catalog,
      this.developmentHTTPOrigin,
      WebPaywallPackageLoader? loader})
      : placements = Map.unmodifiable(placements),
        loader = loader ?? WebPaywallPackageLoader();
  final Map<String, String> placements;
  final Set<String>? allowedOrigins;
  final PaywallCatalog Function() catalog;
  final String? developmentHTTPOrigin;
  final WebPaywallPackageLoader loader;

  /// 忽略未匹配点位，商品与版本只信任发布包，不接受接口中的商品猜测。
  Future<String> transform(
      String source, PaywallConfigurationRequest request) async {
    final positions = _positions(source);
    final mapping = <String, String>{};
    final modes = <String, String>{};
    final pages = <String, Map<String, dynamic>>{};
    final loaded = <String, WebPaywallDocument>{};
    // 同次响应中相同 URL 只加载一次；独立页面失败不丢弃其他有效点位。
    for (final position in positions) {
      if (position is! Map || position['matched'] != true) continue;
      final placement = placements[position['positionKey']];
      final address = position['h5Url'];
      if (placement == null ||
          mapping.containsKey(placement) ||
          address is! String) continue;
      try {
        final document = loaded[address] ?? await _load(address, request);
        loaded[address] = document;
        final existing = pages[document.documentId];
        if (existing != null && existing['pageUrl'] != address) continue;
        if (existing == null && pages.length >= 8) continue;
        mapping[placement] = document.documentId;
        final mode = position['displayModeKey'];
        modes[placement] =
            WebPaywallPresentation.values.any((value) => value.name == mode)
                ? mode as String
                : 'fullScreen';
        pages[document.documentId] = WebPaywallPackage.identity(document);
      } catch (_) {/* 无效包不成为可展示配置，由宿主入口采用明确兜底。 */}
    }
    return jsonEncode({
      'version': 1,
      'placements': mapping,
      'presentations': modes,
      'paywalls': pages,
      'preload': [],
      'sessions': {}
    });
  }

  /// 查询信封限制大小和点位数量，业务错误不能进入配置缓存。
  List<dynamic> _positions(String source) {
    if (utf8.encode(source).length > 1000000)
      throw const FormatException('Query too large');
    final response = jsonDecode(source) as Map<String, dynamic>;
    final positions = response['data'];
    if (response['code'] != '200' ||
        positions is! List ||
        positions.length > 100) {
      throw const FormatException('Invalid query response');
    }
    return positions;
  }

  /// 开发地址仅在 Debug/Test 使用，正式环境不继承本地 HTTP 授权。
  Future<WebPaywallDocument> _load(
          String address, PaywallConfigurationRequest request) =>
      loader.load(Uri.parse(address),
          environment: request.environment.runtimeEnvironment.name,
          allowedOrigins: allowedOrigins,
          catalog: catalog(),
          developmentHTTPOrigin:
              !const bool.fromEnvironment('dart.vm.product') &&
                      !const bool.fromEnvironment('dart.vm.profile') &&
                      request.environment.runtimeEnvironment.name == 'test'
                  ? developmentHTTPOrigin
                  : null);
}
