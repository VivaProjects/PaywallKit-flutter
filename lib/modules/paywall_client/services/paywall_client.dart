import 'dart:convert';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/controllers/web_paywall_controller.dart';
import '../models/paywall_query_configuration.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import 'paywall_query_runtime.dart';
import 'paywall_storage.dart';
import 'dart:async';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../models/paywall_failure.dart';
import 'paywall_local_package_store.dart';
import 'paywall_history_store.dart';

import '../../web_paywall/models/web_paywall_configuration.dart';
import '../models/paywall_configuration_request.dart';
import '../models/paywall_placement.dart';
import 'paywall_configuration_source.dart';

/// 高层配置入口负责请求去重与失效隔离，交易始终由宿主桥接提供。
class PaywallClient {
  PaywallClient(
      {required this.configuration, Set<String> retainedPlacements = const {}})
      : retainedPlacements = Set.unmodifiable(retainedPlacements);

  /// 查询式入口内置归因、前台刷新和本地包更新。
  factory PaywallClient.query(
          {required PaywallQueryConfiguration query,
          required PaywallCatalog Function() catalog,
          PaywallStorage? storage,
          Set<String> retainedPlacements = const {}}) =>
      PaywallQueryRuntime(
              configuration: query,
              catalog: catalog,
              storage: storage,
              retainedPlacements: retainedPlacements)
          .client;

  Future<void> Function({String? channel, bool failed})? attributionReporter;

  /// 宿主仅转交归因 SDK 的结果，等待和持久化由 SDK 管理。
  Future<void> reportAttribution({String? channel, bool failed = false}) async {
    await attributionReporter?.call(channel: channel, failed: failed);
  }

  final PaywallConfigurationSource configuration;
  Future<PaywallPlacement?> Function(String)? queryResolver;
  PaywallPlacement? Function(String)? queryCachedPlacement;
  Future<void> Function()? queryPrepare;
  Future<PaywallPlacement?> Function()? queryFallbackAtLaunch;
  Future<WebPaywallConfiguration> Function()? queryRefresh;
  bool get usesLaunchSnapshot => queryResolver != null;
  final Object identity = Object();
  final Set<String> retainedPlacements;
  final _pages =
      <String, ({Object identity, WebPaywallController controller})>{};

  /// 显式释放缓存页，已挂载页面由其路由独立持有。
  void invalidatePage(String placement) {
    _pages.remove(placement)?.controller.destroyPreload();
  }

  /// 只有已就绪且没有交易进行中的页面才允许跨展示保留。
  bool retainPage(String placement, Object identity, WebPaywallController web) {
    if (!retainedPlacements.contains(placement) || !web.canRetain || _disposed)
      return false;
    invalidatePage(placement);
    web.detachPresentation();
    _pages[placement] = (identity: identity, controller: web);
    return true;
  }

  /// 完整会话身份和宿主价格资格身份同时一致时，重新绑定回调后复用。
  WebPaywallController? takeRetainedPage(
      String placement, Object identity, WebPaywallController fresh) {
    final entry = _pages.remove(placement);
    if (entry == null) return null;
    if (isPlacementDisabled(placement) ||
        entry.identity != identity ||
        !entry.controller.canRetain ||
        entry.controller.sessionIdentity != fresh.sessionIdentity) {
      entry.controller.destroyPreload();
      return null;
    }
    entry.controller.rebind(fresh);
    fresh.dispose();
    return entry.controller;
  }

  /// 同步读取当前配置，重复入口无需等待新的网络结果。
  PaywallPlacement? cachedPlacement(String placement) {
    if (queryCachedPlacement != null) return queryCachedPlacement!(placement);
    final config = _cached;
    final request = _request;
    if (config == null || request == null || isPlacementDisabled(placement))
      return null;
    final document = config.documentForPlacement(placement);
    if (document == null) return null;
    return PaywallPlacement(
        name: placement,
        document: document,
        environment: request.environment.forPlacement(placement),
        presentation: config.presentations[placement]!,
        sessionPolicy: config.sessions[placement],
        requestIdentity: _identity,
        configurationSnapshot: config.source,
        clientIdentity: identity);
  }

  /// 仅预取配置；网页预渲染使用可消费的 PaywallPreload 句柄。
  Future<void> preloadConfiguration() async {
    if (queryPrepare != null) {
      await queryPrepare!();
      return;
    }
    await refresh(force: false);
  }

  PaywallLocalPackageStore? localPackages;
  PaywallHistoryStore? history;
  Set<String> previousVersionPlacements = {};
  Future<WebPaywallEnvironment> Function()? environmentProvider;
  void Function(WebPaywallConfiguration)? didLoad;
  void Function()? onDispose;

  /// 注册显式本地兜底，历史范围只能是已授权回退入口的子集。
  void useLocalPackages(PaywallLocalPackageStore store,
      {PaywallHistoryStore? history,
      Set<String> previousVersionPlacements = const {}}) {
    localPackages = store;
    this.history = history;
    this.previousVersionPlacements =
        previousVersionPlacements.intersection(store.fallbackPlacements);
  }

  /// 任一有效配置显式关闭点位时，所有回退都必须停止。
  bool isPlacementDisabled(String name) =>
      localPackages?.isDisabled(name) == true ||
      _cached?.disabledPlacements.contains(name) == true;

  /// 本地入口无需请求网络，但仍读取当前宿主商店环境。
  Future<WebPaywallEnvironment> currentEnvironment() async =>
      environmentProvider != null
          ? await environmentProvider!()
          : _request?.environment ??
              (await configuration.request()).environment;

  /// 成功首屏才归档，不把预取、下载或失败页当作成功版本。
  Future<void> recordSuccess(
      PaywallPlacement selected, bool Function() isCurrent) async {
    if (!previousVersionPlacements.contains(selected.name) ||
        history == null ||
        selected.requestIdentity == null ||
        selected.configurationSnapshot == null ||
        selected.document.localDirectory != null &&
            selected.remoteDocument == null ||
        isPlacementDisabled(selected.name)) return;
    await history!.record(
        requestIdentity: selected.requestIdentity!,
        placement: selected.name,
        document: selected.remoteDocument ?? selected.document,
        configuration: selected.configurationSnapshot!,
        isCurrent: () =>
            !_disposed && isCurrent() && !isPlacementDisabled(selected.name));
  }

  /// 历史选择仍使用当前来源和目录复验，防止旧配置越权或跨请求使用。
  Future<PaywallPlacement?> previousPlacement(PaywallPlacement current) async {
    if (history == null || current.requestIdentity == null) return null;
    final value = await history!.previous(
        requestIdentity: current.requestIdentity!,
        placement: current.name,
        current: current.document);
    if (value == null) return null;
    if (isPlacementDisabled(current.name)) throw PaywallFailure.disabled;
    final config = WebPaywallConfiguration.parse(value.configuration,
        allowedOrigins: configuration.allowedOrigins,
        catalogs: configuration.catalogs(),
        developmentHTTPOrigin:
            current.environment.runtimeEnvironment.name == 'test'
                ? configuration.developmentHTTPOrigin
                : null);
    final doc = config.documentForPlacement(current.name);
    if (doc == null ||
        doc.documentId != value.document.documentId ||
        doc.revision != value.document.revision ||
        jsonEncode(WebPaywallPackage.identity(doc)) !=
            jsonEncode(WebPaywallPackage.identity(value.document)))
      throw PaywallFailure.configuration;
    return PaywallPlacement(
        name: current.name,
        document: value.document,
        environment: current.environment,
        presentation: config.presentations[current.name]!,
        sessionPolicy: config.sessions[current.name],
        clientIdentity: identity,
        source: 'previous_version');
  }

  WebPaywallConfiguration? _cached;
  PaywallConfigurationRequest? _request;
  Future<WebPaywallConfiguration>? _pending;
  String? _identity;
  int _generation = 0;
  int _epoch = 0;
  int _requestSequence = 0;
  int _appliedSequence = 0;
  bool _disposed = false;

  /// 相同请求共用配置；环境、归因或请求条件变化时清除旧快照。
  Future<WebPaywallConfiguration> refresh({bool force = true}) async {
    if (queryRefresh != null) return queryRefresh!();
    final epoch = _epoch;
    final sequence = ++_requestSequence;
    final request = await configuration.request();
    if (_disposed || epoch != _epoch || sequence < _appliedSequence)
      throw StateError('Stale paywall client');
    _appliedSequence = sequence;
    final identity = request.identity(configuration.cacheNamespace);
    if (_identity == identity && _pending != null) return _pending!;
    if (!force && _identity == identity && _cached != null) return _cached!;
    final current = ++_generation;
    _identity = identity;
    _cached = null;
    _request = request;
    final task = configuration.load(request,
        isCurrent: () => !_disposed && current == _generation);
    _pending = task;
    try {
      final result = await task;
      if (_disposed || current != _generation)
        throw StateError('Stale paywall client');
      _cached = result;
      didLoad?.call(result);
      return result;
    } finally {
      if (current == _generation) _pending = null;
    }
  }

  /// 缺失点位返回空值，显式禁用独立报错；失效旧请求不会取消新的展示等待者。
  Future<PaywallPlacement?> resolve(String placement) async {
    if (queryResolver != null) return queryResolver!(placement);
    while (!_disposed) {
      final epoch = _epoch;
      try {
        await localPackages?.initialize();
        if (isPlacementDisabled(placement)) throw PaywallFailure.disabled;
        final config = await refresh(force: false);
        if (!identical(config, _cached) || _request == null) continue;
        if (isPlacementDisabled(placement)) throw PaywallFailure.disabled;
        return cachedPlacement(placement);
      } catch (_) {
        if (!_disposed && epoch != _epoch) continue;
        rethrow;
      }
    }
    throw PaywallFailure.cancelled;
  }

  /// 归因或宿主配置变化时立即阻断旧结果，下一次解析重新请求。
  void invalidate() {
    _epoch++;
    _generation++;
    _cached = null;
    _pending = null;
    _request = null;
    _identity = null;
  }

  /// 宿主释放入口后，不再接收任何未完成的配置结果。
  void dispose() {
    _disposed = true;
    onDispose?.call();
    for (final page in _pages.values) {
      page.controller.destroyPreload();
    }
    _pages.clear();
    invalidate();
  }
}
