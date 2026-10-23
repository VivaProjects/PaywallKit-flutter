import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/services/web_paywall_diagnostics.dart';
import '../models/paywall_query_configuration.dart';
import '../models/paywall_configuration_request.dart';
import '../models/paywall_placement.dart';
import '../models/paywall_failure.dart';
import 'paywall_client.dart';
import 'paywall_configuration_source.dart';
import 'paywall_query_response.dart';
import 'paywall_query_attribution.dart';
import 'paywall_storage.dart';
import 'paywall_package_archive.dart';
import 'paywall_local_package_store.dart';
import 'paywall_http.dart';

import 'paywall_history_store.dart';
import '../../web_paywall/models/web_paywall_resource_lease.dart';

part 'paywall_query_snapshots.dart';

/// 启动快照冻结已有点位，唯一后台查询只补齐缺失项并保存下次版本。
class PaywallQueryRuntime {
  PaywallQueryRuntime(
      {required this.configuration,
      required this.catalog,
      PaywallStorage? storage,
      Set<String> retainedPlacements = const {}})
      : storage = storage ?? PaywallStorage() {
    attribution = PaywallQueryAttribution(
        storage: this.storage, namespace: configuration.cacheScope);
    response = PaywallQueryResponse(
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
            directory: () =>
                this.storage.folder('query', configuration.cacheScope),
            developmentHTTPOrigin: configuration.developmentHTTPOrigin));
    client.environmentProvider = _environment;
    client.attributionReporter = attribution.update;
    client.onDispose = dispose;
    client.queryResolver = resolve;
    client.queryCachedPlacement = (name) => _active[name];
    client.queryPrepare = prepare;
    client.queryRefresh = refresh;
    client.queryFallbackAtLaunch = fallbackAtLaunch;
    _installFallback();
  }
  final PaywallQueryConfiguration configuration;
  final PaywallCatalog Function() catalog;
  final PaywallStorage storage;
  late final PaywallQueryAttribution attribution;
  late final PaywallQueryResponse response;
  late final PaywallClient client;
  late PaywallPackageArchive _archive;
  late File _index;
  final _records = <String, dynamic>{};
  final _activeRecords = <String, dynamic>{};
  final _active = <String, PaywallPlacement>{};
  final _unavailable = <String>{};
  final _progress = StreamController<void>.broadcast();
  Future<void>? _initializing, _query;
  bool _disposed = false, _finished = false;
  Object? _failure;
  String? _preferredPlacement;
  bool _hasIndex = false;
  PaywallPlacement? _launchFallback;
  final _leases = <WebPaywallResourceLease>[];
  Future<void> _saving = Future.value();

  /// 当前宿主环境必须与查询环境一致，不能跨环境恢复商品绑定。
  Future<WebPaywallEnvironment> _environment() async {
    final env = await configuration.environment();
    env.toPayload();
    if (env.runtimeEnvironment != configuration.runtimeEnvironment) {
      throw PaywallFailure.configuration;
    }
    return env;
  }

  /// 离线等待不消耗归因窗口，迟到归因仅持久化供下个 Client 使用。
  Future<PaywallConfigurationRequest> _request() async {
    await configuration.waitUntilNetworkAvailable?.call();
    _checkActive();
    final channel = await attribution.resolve();
    final env = await _environment();
    _checkActive();
    return PaywallConfigurationRequest.query(
        endpoint: configuration.endpoint,
        environment: env,
        channelKey: channel);
  }

  /// 先恢复完整本地包，再启动唯一后台任务；失败任务也保留到释放。
  Future<void> _start() async {
    await (_initializing ??= _restore());
    _checkActive();
    _query ??= _update();
  }

  /// 已有启动点位立即返回，其他入口只等待自己的完整包。
  Future<PaywallPlacement?> resolve(String name) async {
    _preferredPlacement = name;
    await _start();
    await _wait(name);
    return _active[name];
  }

  /// 配置预热等任一完整点位，不阻塞于其他后台包。
  Future<void> prepare() async {
    await _start();
    await _wait(null);
  }

  /// 通知订阅与状态检查均在同一 isolate，关闭入口不会取消共享查询。
  Future<void> _wait(String? name) async {
    bool available() => name == null
        ? _active.isNotEmpty
        : _active.containsKey(name) || _unavailable.contains(name);
    while (!_disposed && !_finished && !available()) {
      await _progress.stream.first;
    }
    _checkActive();
    if (!available() && _failure != null) throw _failure!;
  }

  /// 有效空响应只移除下次索引；网络或资源错误保留既有候选。
  Future<void> _update() async {
    try {
      final request = await _request();
      await _migrateLegacy(request);
      await configuration.waitUntilNetworkAvailable?.call();
      _checkActive();
      final uri = request.uri;
      if (uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.host.isEmpty ||
          (uri.scheme != 'https' &&
              !(uri.scheme == 'http' &&
                  uri.origin ==
                      client.configuration.developmentOrigin(request)))) {
        throw const FormatException('Invalid query endpoint');
      }
      WebPaywallDiagnostics.log(configuration.runtimeEnvironment.name,
          'query.request', request.body ?? '');
      final raw = await PaywallHttp.fetch(uri,
          method: request.method, body: request.body);
      WebPaywallDiagnostics.log(
          configuration.runtimeEnvironment.name, 'query.response', raw);
      var unmatched = <String>{};
      await response.transform(raw, request,
          preferredPlacement: () => _preferredPlacement,
          onUnavailable: (names) {
            _unavailable.addAll(names);
            _notify();
          },
          onUnmatched: (names) => unmatched = names,
          onPage: (name, doc, mode) => _accept(name, doc, mode, request));
      _checkActive();
      for (final name in unmatched) {
        _records.remove(name);
      }
      await _save();
    } catch (error) {
      _failure = error;
    } finally {
      _finished = true;
      _notify();
    }
  }

  /// 完整资源校验并归档后逐点位唤醒，当前已恢复版本保持冻结。
  Future<void> _accept(String name, WebPaywallDocument doc,
      WebPaywallPresentation mode, PaywallConfigurationRequest request) async {
    final local = await _archive.archive(doc, isCurrent: () => !_disposed);
    _checkActive();
    _records[name] = {
      'document': WebPaywallPackage.identity(doc),
      'presentation': mode.name,
      'requestIdentity': request.identity(configuration.cacheScope),
      'environment': request.environment.toPayload(),
      'requestBody': request.body
    };
    try {
      await _save();
    } catch (_) {/* 持久化失败不阻断当前完整包。 */}
    _checkActive();
    if (!_active.containsKey(name)) {
      _leases.add(WebPaywallResourceLease(local.localDirectory!, () {}));
    }
    _activeRecords.putIfAbsent(name, () => _records[name]);
    _active.putIfAbsent(
        name,
        () => PaywallPlacement(
            name: name,
            document: local,
            environment: request.environment.forPlacement(name),
            presentation: mode,
            requestIdentity: request.identity(configuration.cacheScope),
            clientIdentity: client.identity,
            source: 'disk',
            remoteDocument: doc,
            configurationSnapshot:
                _recordConfiguration(name, _records[name] as Map)));
    _notify();
  }

  /// 本次 Client 的兜底固定为内置包，后台结果通过启动快照提供。
  void _installFallback() {
    final fallback = configuration.fallback;
    if (fallback == null) return;
    final archive = _makeArchive(() => storage.folder(
        'local_packages', '${configuration.cacheScope}.bundled'));
    client.useLocalPackages(
        PaywallLocalPackageStore(
            placement: fallback.placement,
            fallbackPlacements: fallback.fallbackPlacements,
            archive: archive,
            bundled: () => archive.bundled(fallback.bundledAssetPath,
                bundle: fallback.bundle)),
        history: PaywallHistoryStore(
            archive: _makeArchive(
                () => storage.folder('history', configuration.cacheScope))),
        previousVersionPlacements: fallback.previousVersionPlacements);
  }

  /// 独立归档只使用本 SDK 资源校验能力，不依赖 iOS 仓库。
  PaywallPackageArchive _makeArchive(Future<Directory> Function() directory) =>
      PaywallPackageArchive(
          directory: directory,
          environment: configuration.runtimeEnvironment.name,
          cache: response.loader.resourceCache,
          catalog: catalog,
          allowedOrigins: configuration.allowedOrigins,
          developmentHTTPOrigin: configuration.developmentHTTPOrigin);

  /// 唤醒当前等待者，已释放的流不再写入。
  void _notify() {
    if (!_disposed) _progress.add(null);
  }

  /// 所有异步提交都必须确认运行时仍存活。
  void _checkActive() {
    if (_disposed) throw PaywallFailure.cancelled;
  }

  /// 释放只结束等待者，网络晚到结果不能写入索引或重新激活页面。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _progress.add(null);
    unawaited(_progress.close());
    attribution.dispose();
    for (final lease in _leases) {
      lease.release();
    }
    _leases.clear();
  }
}
