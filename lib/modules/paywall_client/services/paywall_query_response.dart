import 'dart:convert';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/services/web_paywall_package_loader.dart';
import '../../web_paywall/services/web_paywall_diagnostics.dart';
import '../models/paywall_configuration_request.dart';

/// 查询信封与包故障分开处理；只有明确未命中才淘汰旧点位。
class PaywallQueryResponse {
  PaywallQueryResponse(
      {required Map<String, String> placements,
      required this.allowedOrigins,
      required this.catalog,
      this.developmentHTTPOrigin,
      this.loadPackage,
      WebPaywallPackageLoader? loader})
      : placements = Map.unmodifiable(placements),
        loader = loader ?? WebPaywallPackageLoader();
  final Map<String, String> placements;
  final Set<String>? allowedOrigins;
  final PaywallCatalog Function() catalog;
  final String? developmentHTTPOrigin;
  final WebPaywallPackageLoader loader;
  final Future<WebPaywallDocument> Function(
      Future<WebPaywallDocument> Function())? loadPackage;

  /// 同时最多准备两个完整包，未开始的下载优先处理可见入口。
  Future<Set<String>> load(
    String source,
    PaywallConfigurationRequest request, {
    required Future<void> Function(String, WebPaywallDocument, String) onPage,
    required void Function(Set<String>) onUnavailable,
    String? Function()? preferredPlacement,
    void Function()? onFailure,
  }) async {
    final selection = _select(source);
    final pending = selection.pending;
    onUnavailable(selection.unmatched);
    final loaded = <String, Future<WebPaywallDocument>>{};
    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final preferred = preferredPlacement?.call();
        final index = pending.indexWhere((p) => p['placement'] == preferred);
        final item = pending.removeAt(index < 0 ? 0 : index);
        final name = item['placement']!;
        try {
          final address = item['address']!;
          final doc = await loaded.putIfAbsent(address, () async {
            try {
              return await (loadPackage?.call(() => _load(address, request)) ??
                  _load(address, request));
            } catch (_) {
              onFailure?.call();
              rethrow;
            }
          });
          await onPage(name, doc, item['mode']!);
        } catch (error) {
          WebPaywallDiagnostics.log(request.environment.runtimeEnvironment.name,
              'query.package_failed', 'placement=$name error=$error');
          // 下载或归档失败只结束此入口等待，不将其当成服务端删除。
          onUnavailable({name});
        }
      }
    }

    await Future.wait([worker(), worker()]);
    return selection.unmatched;
  }

  /// 兼容通用配置转换及既有调用者，增量运行时直接使用 load。
  Future<String> transform(
    String source,
    PaywallConfigurationRequest request, {
    Future<void> Function(String, WebPaywallDocument, WebPaywallPresentation)?
        onPage,
    void Function(Set<String>)? onUnavailable,
    void Function(Set<String>)? onUnmatched,
    String? Function()? preferredPlacement,
  }) async {
    final mapping = <String, String>{};
    final modes = <String, String>{};
    final pages = <String, Map<String, dynamic>>{};
    final unmatched = await load(source, request,
        preferredPlacement: preferredPlacement,
        onUnavailable: onUnavailable ?? (_) {},
        onPage: (name, doc, mode) async {
      if (pages.length >= WebPaywallConfiguration.maxPages &&
          !pages.containsKey(doc.documentId)) return;
      mapping[name] = doc.documentId;
      modes[name] = mode;
      pages[doc.documentId] = WebPaywallPackage.identity(doc);
      await onPage?.call(name, doc, WebPaywallPresentation.values.byName(mode));
    });
    onUnmatched?.call(unmatched);
    return jsonEncode({
      'version': 1,
      'placements': mapping,
      'presentations': modes,
      'paywalls': pages,
      'preload': [],
      'sessions': {}
    });
  }

  /// 单点位配置作为持久快照，避免同文档多版本互相覆盖。
  static String configurationFor(
          String name, WebPaywallDocument doc, String mode) =>
      jsonEncode({
        'version': 1,
        'placements': {name: doc.documentId},
        'presentations': {name: mode},
        'paywalls': {doc.documentId: WebPaywallPackage.identity(doc)},
        'preload': [],
        'sessions': {},
      });

  /// 重复点位或非法 matched 字段属于响应错误，不能触发缓存删除。
  ({List<Map<String, String>> pending, Set<String> unmatched}) _select(
      String source) {
    final positions = _positions(source);
    final seen = <String>{};
    final unmatched = <String>{};
    final pending = <Map<String, String>>[];
    for (final item in positions) {
      if (item is! Map ||
          item['positionKey'] is! String ||
          item['matched'] is! bool) {
        throw const FormatException('Invalid query position');
      }
      final name = placements[item['positionKey']];
      if (name == null) continue;
      if (!seen.add(name))
        throw const FormatException('Duplicate query position');
      if (item['matched'] == false) {
        unmatched.add(name);
        continue;
      }
      final mode = item['displayModeKey'];
      pending.add({
        'placement': name,
        'address': item['h5Url'] is String ? item['h5Url'] as String : '',
        'mode': WebPaywallPresentation.values.any((v) => v.name == mode)
            ? mode as String
            : 'fullScreen'
      });
    }
    unmatched.addAll(placements.values.toSet().difference(seen));
    return (pending: pending, unmatched: unmatched);
  }

  /// 信封大小和状态码严格校验，网络或业务错误不得覆盖缓存。
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

  /// 页面地址只用于定位完整发布包，商品来自环境绑定和真实宿主目录。
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
