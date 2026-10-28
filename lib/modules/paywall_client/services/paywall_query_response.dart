import 'paywall_query_package_batch.dart';
import '../../web_paywall/models/web_paywall_resource_lease.dart';
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
        loader = loader ?? WebPaywallPackageLoader(),
        _usesCustomLoader = loader != null;
  final Map<String, String> placements;
  final Set<String>? allowedOrigins;
  final PaywallCatalog Function() catalog;
  final String? developmentHTTPOrigin;
  final WebPaywallPackageLoader loader;
  final bool _usesCustomLoader;
  final Future<WebPaywallDocument> Function(
      Future<WebPaywallDocument> Function())? loadPackage;

  /// 同时最多下载两个完整包，归档期间每个工作者最多提前准备一个包。
  Future<Set<String>> load(
    String source,
    PaywallConfigurationRequest request, {
    required Future<void> Function(String, WebPaywallDocument, String) onPage,
    Future<void> Function(
            String, WebPaywallDocument, String, WebPaywallResourceLease)?
        onPreparedPage,
    required void Function(Set<String>) onUnavailable,
    String? Function()? preferredPlacement,
    void Function()? onFailure,
  }) async {
    final selection = _select(source);
    final grouped = <String, List<Map<String, String>>>{};
    for (final item in selection.pending) {
      grouped.putIfAbsent(item['address']!, () => []).add(item);
    }
    final pending = grouped.values.toList();
    onUnavailable(selection.unmatched);
    final batch = PaywallQueryPackageBatch(
        selection.pending.map((item) => item['address']!),
        _usesCustomLoader ? loader : null);
    Future<void> worker() => _drainPackages(pending, batch, request,
        preferredPlacement, onFailure, onPage, onPreparedPage, onUnavailable);

    try {
      await Future.wait([worker(), worker()]);
    } finally {
      await batch.settle();
      batch.dispose();
    }
    return selection.unmatched;
  }

  /// 每个工作者最多预取一个包，归档与下一包下载重叠，不增加同时下载数。
  Future<void> _drainPackages(
      List<List<Map<String, String>>> pending,
      PaywallQueryPackageBatch batch,
      PaywallConfigurationRequest request,
      String? Function()? preferredPlacement,
      void Function()? onFailure,
      Future<void> Function(String, WebPaywallDocument, String) onPage,
      Future<void> Function(
              String, WebPaywallDocument, String, WebPaywallResourceLease)?
          onPreparedPage,
      void Function(Set<String>) onUnavailable) async {
    var current =
        _takePackage(pending, batch, request, preferredPlacement, onFailure);
    while (current != null) {
      final items = current.items;
      final document = current.document;
      final address = items.first['address']!;
      // 完整下载结束才释放网络槽；异常交给各点位原有处理路径。
      try {
        await document;
      } catch (_) {}
      current =
          _takePackage(pending, batch, request, preferredPlacement, onFailure);
      while (items.isNotEmpty) {
        final item = _takeTarget(items, preferredPlacement?.call());
        try {
          await _deliver(item, request, document, batch.resources, onPage,
              onPreparedPage, onUnavailable);
        } finally {
          await batch.finish(address, document);
        }
      }
    }
  }

  /// 仅领取尚未开始的包，已开始的预取保留身份、重试与完整校验。
  ({List<Map<String, String>> items, Future<WebPaywallDocument> document})?
      _takePackage(
          List<List<Map<String, String>>> pending,
          PaywallQueryPackageBatch batch,
          PaywallConfigurationRequest request,
          String? Function()? preferredPlacement,
          void Function()? onFailure) {
    if (pending.isEmpty) return null;
    final preferred = preferredPlacement?.call();
    final index = pending.indexWhere(
        (items) => items.any((item) => item['placement'] == preferred));
    final items = pending.removeAt(index < 0 ? 0 : index);
    final address = items.first['address']!;
    return (
      items: items,
      document: batch.load(address,
          (loader) => _loadRetried(address, request, loader, onFailure))
    );
  }

  /// 同包内部也优先交付当前可见点位，避免别名归档推迟用户正在等待的入口。
  Map<String, String> _takeTarget(
      List<Map<String, String>> items, String? preferred) {
    final index = items.indexWhere((item) => item['placement'] == preferred);
    return items.removeAt(index < 0 ? 0 : index);
  }

  /// 下载重试只创建一份资源租约，别名点位共享同一个完成结果。
  Future<WebPaywallDocument> _loadRetried(
      String address,
      PaywallConfigurationRequest request,
      WebPaywallPackageLoader activeLoader,
      void Function()? onFailure) async {
    try {
      return await (loadPackage
              ?.call(() => _load(address, request, activeLoader)) ??
          _load(address, request, activeLoader));
    } catch (_) {
      onFailure?.call();
      rethrow;
    }
  }

  /// 单点位交付失败不提前释放共享资源；最后一个别名退出后归还。
  Future<void> _deliver(
      Map<String, String> item,
      PaywallConfigurationRequest request,
      Future<WebPaywallDocument> pending,
      Map<WebPaywallDocument, WebPaywallResourceLease> resources,
      Future<void> Function(String, WebPaywallDocument, String) onPage,
      Future<void> Function(
              String, WebPaywallDocument, String, WebPaywallResourceLease)?
          onPreparedPage,
      void Function(Set<String>) onUnavailable) async {
    final name = item['placement']!;
    try {
      final doc = await pending;
      final resource = resources[doc];
      if (resource != null && onPreparedPage != null) {
        await onPreparedPage(name, doc, item['mode']!, resource);
      } else {
        await onPage(name, doc, item['mode']!);
      }
    } catch (error) {
      WebPaywallDiagnostics.log(request.environment.runtimeEnvironment.name,
          'query.package_failed', 'placement=$name error=$error');
      // 下载或归档失败只结束此入口等待，不将其当成服务端删除。
      onUnavailable({name});
    }
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
          String address,
          PaywallConfigurationRequest request,
          WebPaywallPackageLoader activeLoader) =>
      activeLoader.load(Uri.parse(address),
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
