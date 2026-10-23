import 'dart:convert';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/services/web_paywall_package_loader.dart';
import '../models/paywall_configuration_request.dart';

/// 查询结果逐包提交，两条下载流水线互不阻塞，坏包只影响关联点位。
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

  /// 信封校验后先通知缺失项，完整包逐个通知，保持原 transform 兼容接口。
  Future<String> transform(
    String source,
    PaywallConfigurationRequest request, {
    Future<void> Function(String, WebPaywallDocument, WebPaywallPresentation)?
        onPage,
    void Function(Set<String>)? onUnavailable,
    void Function(Set<String>)? onUnmatched,
    String? Function()? preferredPlacement,
  }) async {
    final candidates = _classify(source, onUnavailable, onUnmatched);
    final batch = _QueryBatch();
    // 两个 worker 共用 URL Future，同包只下载一次；提交函数负责串行写索引。
    Future<void> worker() async {
      while (candidates.isNotEmpty) {
        final preferred = preferredPlacement?.call();
        final index = candidates.indexWhere((p) =>
            preferred != null && placements[p['positionKey']] == preferred);
        final position = candidates.removeAt(index < 0 ? 0 : index);
        await _accept(position, request, batch, onPage);
      }
    }

    await Future.wait([worker(), worker()]);
    return jsonEncode({
      'version': 1,
      'placements': batch.mapping,
      'presentations': batch.modes,
      'paywalls': batch.pages,
      'preload': [],
      'sessions': {}
    });
  }

  /// 明确缺失才撤销下次缓存，资源加载失败的候选仍保留旧记录。
  List<Map> _classify(String source, void Function(Set<String>)? onUnavailable,
      void Function(Set<String>)? onUnmatched) {
    final positions = _positions(source).whereType<Map>().toList();
    final returned = positions
        .map((p) => placements[p['positionKey']])
        .whereType<String>()
        .toSet();
    final candidates = positions
        .where((p) => p['matched'] == true && p['h5Url'] is String)
        .toList();
    final names = candidates
        .map((p) => placements[p['positionKey']])
        .whereType<String>()
        .toSet();
    final unmatched = placements.values.toSet().difference(returned);
    unmatched.addAll(positions
        .where((p) => p['matched'] == false)
        .map((p) => placements[p['positionKey']])
        .whereType<String>());
    onUnavailable?.call(placements.values.toSet().difference(names));
    onUnmatched?.call(unmatched.difference(names));
    return candidates;
  }

  /// 共享下载结果，拒绝同文档 ID 不同来源冲突，失败保留旧缓存候选。
  Future<void> _accept(
      Map position,
      PaywallConfigurationRequest request,
      _QueryBatch batch,
      Future<void> Function(String, WebPaywallDocument, WebPaywallPresentation)?
          onPage) async {
    final name = placements[position['positionKey']];
    final address = position['h5Url'];
    if (name == null || address is! String || batch.mapping.containsKey(name))
      return;
    try {
      final document = await batch.loaded
          .putIfAbsent(address, () => _load(address, request));
      final existing = batch.pages[document.documentId];
      // 并行下载完成后再次判断，重复点位只能提交一次。
      if (batch.mapping.containsKey(name) ||
          existing != null && existing['pageUrl'] != address ||
          existing == null && batch.pages.length >= 8) return;
      final mode = WebPaywallPresentation.values
              .where((v) => v.name == position['displayModeKey'])
              .firstOrNull ??
          WebPaywallPresentation.fullScreen;
      batch.mapping[name] = document.documentId;
      batch.modes[name] = mode.name;
      batch.pages[document.documentId] = WebPaywallPackage.identity(document);
      await onPage?.call(name, document, mode);
    } catch (_) {/* 单个资源异常不撤销其他已经提交的完整点位。 */}
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

/// 单次响应内部状态，避免并行任务各自覆盖最终配置。
class _QueryBatch {
  final mapping = <String, String>{};
  final modes = <String, String>{};
  final pages = <String, Map<String, dynamic>>{};
  final loaded = <String, Future<WebPaywallDocument>>{};
}
