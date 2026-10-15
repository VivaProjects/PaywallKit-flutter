import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../models/paywall_query_configuration.dart';
import '../models/paywall_configuration_request.dart';
import '../models/paywall_failure.dart';
import 'paywall_client.dart';
import 'paywall_configuration_source.dart';
import 'paywall_query_response.dart';
import 'paywall_query_attribution.dart';
import 'paywall_storage.dart';
import 'paywall_package_archive.dart';
import 'paywall_local_package_store.dart';
import 'paywall_history_store.dart';

/// SDK 自行协调归因等待、商店变更、前台刷新与按请求隔离的本地仓库。
class PaywallQueryRuntime with WidgetsBindingObserver {
  PaywallQueryRuntime(
      {required this.configuration,
      required this.catalog,
      PaywallStorage? storage,
      Set<String> retainedPlacements = const {}})
      : storage = storage ?? PaywallStorage() {
    attribution = PaywallQueryAttribution(
        storage: this.storage, namespace: configuration.cacheScope);
    final response = PaywallQueryResponse(
        placements: configuration.placements,
        allowedOrigins: configuration.allowedOrigins,
        catalog: catalog,
        developmentHTTPOrigin: configuration.developmentHTTPOrigin);
    client = PaywallClient(
        retainedPlacements: retainedPlacements,
        configuration: PaywallConfigurationSource(
            cacheNamespace: configuration.cacheScope,
            allowedOrigins: configuration.allowedOrigins,
            catalogs: () => {'default': catalog()},
            request: _request,
            transform: response.transform,
            developmentHTTPOrigin: configuration.developmentHTTPOrigin,
            directory: () =>
                this.storage.folder('query', configuration.cacheScope)));
    client.environmentProvider = _environment;
    client.didLoad = _didLoad;
    client.onDispose = dispose;
    client.attributionReporter = attribution.update;
    attribution.onChange = _attributionChanged;
    _selectStore('bundled');
    _storefront = configuration.storefrontChanges?.listen(_storefrontChanged);
    WidgetsBinding.instance.addObserver(this);
  }
  final PaywallQueryConfiguration configuration;
  final PaywallCatalog Function() catalog;
  final PaywallStorage storage;
  late final PaywallQueryAttribution attribution;
  late final PaywallClient client;
  final _stores = <String, PaywallLocalPackageStore>{};
  final _histories = <String, PaywallHistoryStore>{};
  StreamSubscription<String>? _storefront;
  String? _activeIdentity, _activeChannel, _activeCountry;
  DateTime? _lastRefresh;
  Future<void>? _refreshing;
  int _generation = 0;
  bool _disposed = false;

  /// 标准环境与查询环境必须一致，否则直接拒绝而非跨环境借用商品。
  Future<WebPaywallEnvironment> _environment() async {
    final value = await configuration.environment();
    if (value.runtimeEnvironment != configuration.runtimeEnvironment)
      throw PaywallFailure.configuration;
    value.toPayload();
    return value;
  }

  /// 先解析归因，再动态取得商店与设备条件并冻结请求身份。
  Future<PaywallConfigurationRequest> _request() async {
    final channel = await attribution.resolve();
    final env = await _environment();
    if (_disposed || channel != (attribution.channel ?? 'organic'))
      throw PaywallFailure.cancelled;
    final request = PaywallConfigurationRequest.query(
        endpoint: configuration.endpoint,
        environment: env,
        channelKey: channel);
    final identity = request.identity(configuration.cacheScope);
    if (identity != _activeIdentity) _selectStore(identity);
    _activeIdentity = identity;
    _activeChannel = channel;
    _activeCountry = env.validatedCountry;
    return request;
  }

  /// 相同请求复用仓库，旧展示还持有的文件不被新实例清理。
  void _selectStore(String identity) {
    final fallback = configuration.fallback;
    if (fallback == null) return;
    final scope = '${configuration.cacheScope}.$identity';
    final archive = PaywallPackageArchive(
        directory: () => storage.folder('local_packages', scope),
        environment: configuration.runtimeEnvironment.name,
        catalog: catalog,
        allowedOrigins: configuration.allowedOrigins,
        developmentHTTPOrigin: configuration.developmentHTTPOrigin);
    final store = _stores.putIfAbsent(
        identity,
        () => PaywallLocalPackageStore(
            placement: fallback.placement,
            fallbackPlacements: fallback.fallbackPlacements,
            archive: archive,
            updateUrl: fallback.updateUrl,
            bundled: () => archive.bundled(fallback.bundledAssetPath,
                bundle: fallback.bundle)));
    final history = _histories.putIfAbsent(
        identity,
        () => PaywallHistoryStore(
            archive: PaywallPackageArchive(
                directory: () =>
                    storage.folder('history', configuration.cacheScope),
                environment: configuration.runtimeEnvironment.name,
                catalog: catalog,
                allowedOrigins: configuration.allowedOrigins,
                developmentHTTPOrigin: configuration.developmentHTTPOrigin)));
    client.useLocalPackages(store,
        history: history,
        previousVersionPlacements: fallback.previousVersionPlacements);
  }

  /// 有效配置触发兜底包更新，更新失败不影响当前会话或内置包。
  void _didLoad(WebPaywallConfiguration value) {
    _lastRefresh = DateTime.now();
    final fallback = configuration.fallback;
    final store = client.localPackages;
    if (fallback == null || store == null) return;
    final document = value.documentForPlacement(fallback.placement);
    if (document == null) return;
    final generation = _generation;
    unawaited(store
        .adopt(document,
            isCurrent: () => !_disposed && generation == _generation)
        .catchError((Object _) {}));
  }

  /// 归因变化使旧请求立即失效，已经显示的页面仍保留原快照。
  void _attributionChanged() {
    if (_activeChannel != null && _activeChannel != attribution.channel)
      _invalidate();
  }

  /// 商店账户国家变化后刷新路由，绝不使用设备地区推断。
  void _storefrontChanged(String country) {
    if (_activeCountry != null && _activeCountry != country.toUpperCase())
      _invalidate();
  }

  /// 先切回内置范围，再调度新请求，避免旧归因更新包泄漏给新请求。
  void _invalidate() {
    _generation++;
    client.invalidate();
    _refreshing = null;
    _activeIdentity = _activeChannel = _activeCountry = null;
    _selectStore('bundled');
    unawaited(refreshIfNeeded(force: true).catchError((Object _) {}));
  }

  /// 前台恢复自动检查，保持每小时最多一次刷新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed)
      unawaited(refreshIfNeeded().catchError((Object _) {}));
  }

  /// 前台也重新采集商店条件，支持没有国家变化流的平台宿主。
  Future<void> refreshIfNeeded({bool force = false}) async {
    if (_disposed) return;
    final env = await _environment();
    if (_activeCountry != null && env.validatedCountry != _activeCountry)
      force = true;
    if (!force &&
        _lastRefresh != null &&
        DateTime.now().difference(_lastRefresh!) < const Duration(hours: 1))
      return;
    if (_refreshing != null) return _refreshing;
    _lastRefresh = DateTime.now();
    final task = _refresh();
    _refreshing = task;
    try {
      await task;
    } finally {
      if (identical(_refreshing, task)) _refreshing = null;
    }
  }

  /// 失败保留已校验副本和内置包，不把后台错误抛入应用事件循环。
  Future<void> _refresh() async {
    try {
      await client.refresh();
      await client.localPackages?.refreshIfNeeded();
    } catch (_) {/* 下次前台恢复或宿主重试重新请求。 */}
  }

  /// Client 释放时注销前台与商店监听，同时取消归因等待。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    attribution.dispose();
    unawaited(_storefront?.cancel());
    WidgetsBinding.instance.removeObserver(this);
  }
}
