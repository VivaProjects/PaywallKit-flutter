import '../../web_paywall/models/web_paywall_resource_lease.dart';
import 'dart:async';
import 'dart:convert';
import '../models/paywall_query_update_diagnostic.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import 'paywall_query_retry.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_session_policy.dart';
import '../../web_paywall/services/web_paywall_resource_cache.dart';
import '../../web_paywall/services/web_paywall_diagnostics.dart';
import '../models/paywall_query_configuration.dart';
import '../models/paywall_configuration_request.dart';
import '../models/paywall_failure.dart';
import '../models/paywall_placement.dart';
import 'paywall_client.dart';
import 'paywall_configuration_source.dart';
import 'paywall_query_response.dart';
import 'paywall_query_attribution.dart';
import 'paywall_query_snapshots.dart';
import 'paywall_query_archive_batch.dart';
import '../../web_paywall/services/web_paywall_resource_preparation.dart';
import 'paywall_storage.dart';
import 'paywall_package_archive.dart';
import 'paywall_local_package_store.dart';
import 'paywall_history_store.dart';
import 'paywall_http.dart';

part 'paywall_query_update.dart';

/// 相同查询域共用一次启动任务；各 Client 仍持有自己的兜底授权和网页。
class PaywallQueryRuntime {
  final String _diagnosticID = Object().hashCode.toRadixString(16);
  PaywallQueryRuntime._(this.configuration, this.catalog, this.storage) {
    attribution = PaywallQueryAttribution(
        storage: storage, namespace: configuration.cacheScope);
    snapshots = PaywallQuerySnapshots(configuration, catalog, storage,
        isCurrent: () => !_disposed);
  }
  static final _sessions = <String, PaywallQueryRuntime>{};
  final PaywallQueryConfiguration configuration;
  final PaywallCatalog Function() catalog;
  final PaywallStorage storage;
  late final PaywallQueryAttribution attribution;
  late final PaywallQuerySnapshots snapshots;
  final _clients = <PaywallClient>{};
  final _active = <String, PaywallPlacement>{};
  final _launch = <String, PaywallPlacement>{};
  final _unavailable = <String>{};
  final _deferred = <String>{};
  int _updatedPlacements = 0, _updateFailures = 0;
  final _progress = StreamController<void>.broadcast();
  final _cancelled = Completer<void>();
  Future<void>? _restoring, _query;
  bool _finished = false, _disposed = false;
  Object? _failure;
  String? _preferred;

  /// 显式共享命名空间与端点，普通墙和结果墙不会重复发送接口请求。
  static PaywallClient connect(
      {required PaywallQueryConfiguration configuration,
      required PaywallCatalog Function() catalog,
      PaywallStorage? storage,
      Set<String> retainedPlacements = const {}}) {
    final key =
        '${configuration.cacheScope}|${configuration.endpoint}|${PaywallStorage.digest(configuration.placements)}|${PaywallStorage.digest(configuration.allowedOrigins == null ? 'unrestricted' : (configuration.allowedOrigins!.toList()..sort()))}|${configuration.developmentHTTPOrigin}';
    final runtime = _sessions.putIfAbsent(
        key,
        () => PaywallQueryRuntime._(
            configuration, catalog, storage ?? PaywallStorage()));
    return runtime._attach(configuration, retainedPlacements, key);
  }

  /// Client 的兜底仓库与查询快照分离，防止结果页借用 Settings 包。
  PaywallClient _attach(
      PaywallQueryConfiguration config, Set<String> retained, String key) {
    final source = _source(config.cacheScope);
    // 展示缓存仍由调用 Client 持有，只有查询与点位快照共用。
    final client =
        PaywallClient(configuration: source, retainedPlacements: retained);
    _clients.add(client);
    client.environmentProvider = config.environment;
    client.attributionReporter = attribution.update;
    client.queryPrepare = prepare;
    client.queryUpdate = waitForUpdate;
    client.queryPlacementNames = config.placements.values.toSet();
    client.queryRestore = restore;
    client.queryRestorePlacement = restorePlacement;
    client.queryRestorePrepared =
        (name, preparation) => restorePlacement(name, preparation: preparation);
    client.queryResolvePrepared = (name, presentation, preparation) => resolve(
        name, client,
        presentation: presentation, preparation: preparation);
    client.queryResolve = (name) => resolve(name, client);
    client.queryResolveForPresentation =
        (name) => resolve(name, client, presentation: true);
    client.queryCached = (name) => _bind(_active[name], client);
    client.queryLaunchFallback = (name) => _bind(_launch[name], client);
    client.onDispose = () => _detach(client, key);
    // 独立注册各域的兜底授权，结果页不能扩大回退范围。
    _installFallback(client, config);
    return client;
  }

  /// 内置包固定在独立新域，不继承旧更新仓库中的可变指针。
  void _installFallback(
      PaywallClient client, PaywallQueryConfiguration config) {
    final fallback = config.fallback;
    if (fallback == null) return;
    final archive = PaywallPackageArchive(
        directory: () => storage.folder('local_packages',
            '${config.cacheScope}.bundled.${fallback.placement}'),
        environment: config.runtimeEnvironment.name,
        catalog: catalog,
        allowedOrigins: config.allowedOrigins,
        developmentHTTPOrigin: config.developmentHTTPOrigin);
    client.useLocalPackages(
        PaywallLocalPackageStore(
            placement: fallback.placement,
            fallbackPlacements: fallback.fallbackPlacements,
            archive: archive,
            bundled: () => archive.bundled(fallback.bundledAssetPath,
                bundle: fallback.bundle),
            bundledPrepared: (preparation) => archive.bundledForPreparation(
                fallback.bundledAssetPath, preparation,
                bundle: fallback.bundle)),
        history: PaywallHistoryStore(
            archive: PaywallPackageArchive(
                directory: () => storage.folder(
                    'history', '${config.cacheScope}.${fallback.placement}'),
                environment: config.runtimeEnvironment.name,
                catalog: catalog,
                allowedOrigins: config.allowedOrigins,
                developmentHTTPOrigin: config.developmentHTTPOrigin)),
        previousVersionPlacements: fallback.previousVersionPlacements);
  }

  /// 旧配置仅用于精确身份迁移，不触发其网络回退路径。
  PaywallConfigurationSource _source(String namespace) =>
      PaywallConfigurationSource(
          cacheNamespace: namespace,
          allowedOrigins: configuration.allowedOrigins,
          catalogs: () => {'default': catalog()},
          request: _request,
          developmentHTTPOrigin: configuration.developmentHTTPOrigin,
          directory: () => storage.folder('query', namespace));

  /// 恢复只访问磁盘；离线也能立即使用已经校验的完整包。
  Future<void> restore() => _restoring ??= _restore();

  /// 冻结启动版本；每个已校验点位立即唤醒等待者。
  Future<void> _restore() async {
    await snapshots.restore(
        preferredPlacement: () => _preferred, onPlacement: _publishRestored);
    if (_disposed) throw PaywallFailure.cancelled;
  }

  /// 同一点位多入口恢复只发布一次，后台结果不能替换启动快照。
  void _publishRestored(PaywallPlacement value) {
    if (_disposed || _active.containsKey(value.name)) return;
    _active[value.name] = value;
    _launch[value.name] = value;
    _trace('query.cache_restored', 'placement=${value.name}');
    _progress.add(null);
  }

  /// 本地入口只等自己的校验；其余快照继续恢复，不触发网络查询。
  Future<void> restorePlacement(String name,
      {WebPaywallResourcePreparation? preparation}) async {
    _preferred = name;
    final value = await WebPaywallDiagnostics.measure(
        configuration.runtimeEnvironment.name,
        'snapshot.restore',
        () => snapshots.restorePlacement(name, preparation: preparation),
        detail: 'query=$_diagnosticID placement=$name');
    if (_disposed) throw PaywallFailure.cancelled;
    if (value != null) _publishRestored(value);
    unawaited(restore().catchError((Object _) {}));
  }

  /// 首个完整缓存即可结束预备，剩余恢复与后台更新在共享任务中继续。
  Future<void> prepare() async {
    _start();
    await _wait(null);
  }

  /// 可见入口只等待自己，关闭等待者不会中止共享后台更新。
  Future<PaywallPlacement?> resolve(String name, PaywallClient client,
      {bool presentation = false,
      WebPaywallResourcePreparation? preparation}) async {
    await restorePlacement(name, preparation: preparation);
    _start();
    final timer = presentation
        ? Timer(const Duration(seconds: 3), () {
            if (_disposed ||
                _finished ||
                _active.containsKey(name) ||
                _unavailable.contains(name)) return;
            _deferred.add(name);
            _trace('query.presentation_timeout', 'placement=$name seconds=3');
            _progress.add(null);
          })
        : null;
    try {
      await _wait(name);
    } finally {
      timer?.cancel();
    }
    return _bind(_active[name], client);
  }

  /// 监听先注册后再次检查，避免下载完成落在检查与订阅之间。
  Future<void> _wait(String? name) async {
    bool ready() => name == null
        ? _active.isNotEmpty
        : _active.containsKey(name) ||
            _unavailable.contains(name) ||
            _deferred.contains(name);
    while (!ready() && !_finished && !_disposed) {
      final next = _progress.stream.first;
      if (ready() || _finished || _disposed) break;
      await next;
    }
    if (_disposed) throw PaywallFailure.cancelled;
    if (!ready() && _failure != null) throw _failure!;
  }

  /// 诊断和回归可等待本次静默更新完成，不产生额外请求。
  Future<void> waitForUpdate() async {
    _start();
    await _query;
  }

  /// 成功或失败都保留唯一任务，恢复前台和迟到归因不会重新查询。
  void _start() {
    if (_query != null || _disposed) return;
    _query = _update().catchError((Object error) {
      _failure = error;
      _trace('query.update_failed', '${error.runtimeType}');
      if (!_disposed && error != PaywallFailure.cancelled)
        _report(const PaywallQueryUpdateDiagnostic.failed());
    }).whenComplete(() {
      _finished = true;
      if (!_disposed) _progress.add(null);
    });
  }

  /// 网络未知或离线时等待，归因超时从联网以后开始。
  Future<void> _online() async {
    final wait = configuration.waitUntilNetworkAvailableCancellable;
    if (wait != null) {
      await wait(_cancelled.future);
    } else {
      final legacy = configuration.waitUntilNetworkAvailable;
      if (legacy != null) {
        await Future.any([legacy(), _cancelled.future]);
      }
    }
    if (_disposed) throw PaywallFailure.cancelled;
  }

  /// 首次请求条件只采集一次；迟到归因只写入下次启动的存储。
  Future<PaywallConfigurationRequest> _request() async {
    final environment = configuration.runtimeEnvironment.name;
    await WebPaywallDiagnostics.measure(
        environment, 'query.network_wait', _online,
        detail: 'query=$_diagnosticID');
    final channel = await WebPaywallDiagnostics.measure(
        environment, 'query.attribution', attribution.resolve,
        detail: 'query=$_diagnosticID');
    final env = await WebPaywallDiagnostics.measure(
        environment, 'query.environment', configuration.environment,
        detail: 'query=$_diagnosticID');
    if (_disposed) throw PaywallFailure.cancelled;
    if (env.runtimeEnvironment != configuration.runtimeEnvironment)
      throw PaywallFailure.configuration;
    env.toPayload();
    return PaywallConfigurationRequest.query(
        endpoint: configuration.endpoint,
        environment: env,
        channelKey: channel);
  }

  /// 合法信封先选择点位，完整包逐个提交，未命中只删除下次启动索引。
  Future<void> _update() async {
    // 请求可以与磁盘恢复重叠；两者完成前不迁移、下载或提交任何新指针。
    final requestTask = _prepareRequest();
    final responseTask = _fetchUpdate(requestTask);
    final results = await Future.wait<Object?>([restore(), requestTask]);
    final request = results[1] as PaywallConfigurationRequest;
    if (_disposed) return;
    // 先按当前请求身份迁移，迁移不允许下载或跨环境寻找旧资源。
    await _migrate(request);
    if (_disposed) return;
    final (raw, error, stack) = await responseTask;
    if (_disposed) return;
    if (error != null) Error.throwWithStackTrace(error, stack!);
    final archiveBatch = PaywallQueryArchiveBatch();
    // 完整包增量提交；失败点位与明确未命中使用不同处理路径。
    final response = PaywallQueryResponse(
        placements: configuration.placements,
        loader: configuration.packageLoader,
        loadPackage: (operation) => _retry(operation, 'package'),
        allowedOrigins: configuration.allowedOrigins,
        catalog: catalog,
        developmentHTTPOrigin: configuration.developmentHTTPOrigin);
    final unmatched = await response.load(raw!, request,
        preferredPlacement: () => _preferred,
        onUnavailable: _markUnavailable,
        onFailure: () => _updateFailures++,
        onPage: (name, doc, mode) =>
            _acceptUpdate(name, doc, mode, request, batch: archiveBatch),
        onPreparedPage: (name, doc, mode, resource) => _acceptUpdate(
            name, doc, mode, request,
            resource: resource, batch: archiveBatch));
    if (_disposed) return;
    // 删除只作用于磁盘索引，不撤换已经恢复的本次启动版本。
    try {
      await snapshots.remove(unmatched, () => !_disposed);
    } catch (_) {
      _updateFailures++;
    }
    _report(PaywallQueryUpdateDiagnostic.completed(
        updatedPlacements: _updatedPlacements, failures: _updateFailures));
    _trace('query.update_finished',
        'updated=$_updatedPlacements failures=$_updateFailures unmatched=${unmatched.length}');
  }

  /// 归档失败时仍可使用本次已校验资源，但不得替换旧持久指针。
  Future<bool> _accept(String name, WebPaywallDocument doc, String mode,
      PaywallConfigurationRequest request,
      {WebPaywallResourceLease? resource,
      PaywallQueryArchiveBatch? batch,
      String? configurationSnapshot,
      WebPaywallSessionPolicy? sessionPolicy}) async {
    if (_disposed) throw PaywallFailure.cancelled;
    var value = PaywallPlacement(
        name: name,
        document: doc,
        environment: request.environment.forPlacement(name),
        presentation: WebPaywallPresentation.values.byName(mode),
        requestIdentity: request.identity(configuration.cacheScope),
        sessionPolicy: sessionPolicy,
        configurationSnapshot: configurationSnapshot ??
            PaywallQueryResponse.configurationFor(name, doc, mode));
    var saved = true;
    // 持久化成功才移动下次启动指针，磁盘错误不影响本次已下载包。
    try {
      value = await snapshots.save(value, () => !_disposed,
          resource: resource, batch: batch);
    } catch (error) {
      saved = false;
      _updateFailures++;
      _trace('query.snapshot_failed', 'placement=$name error=$error');
    }
    if (_disposed) return false;
    // 当前已有版本保持不变，仅缺失入口立即使用新包。
    if (!_active.containsKey(name) && !_deferred.contains(name)) {
      _active[name] = value;
      _progress.add(null);
    }
    _trace('query.cache_staged', 'placement=$name revision=${doc.revision}');
    return saved;
  }

  /// 没有新索引时只迁移精确请求对应的旧配置和已存在资源，不为迁移下载。
  Future<void> _migrate(PaywallConfigurationRequest request) async {
    if (snapshots.hasIndex) return;
    for (final namespace in {
      configuration.cacheScope,
      ...configuration.legacyCacheNamespaces
    }) {
      try {
        final old = await _source(namespace).readCached(request);
        for (final name in old.placements.keys) {
          if (_active.containsKey(name) ||
              !configuration.placements.containsValue(name)) continue;
          try {
            final doc = old.documentForPlacement(name)!;
            final lease = await WebPaywallResourceCache.shared
                .cached(doc, configuration.runtimeEnvironment.name);
            try {
              await _accept(name, doc.withLocalDirectory(lease.directory),
                  old.presentations[name]!.name, request,
                  configurationSnapshot: old.source,
                  sessionPolicy: old.sessions[name]);
              if (_active[name] != null) _launch[name] = _active[name]!;
            } finally {
              lease.release();
            }
          } catch (_) {/* 缺失或损坏包不参与旧缓存迁移。 */}
        }
      } catch (_) {/* 没有精确身份旧配置时等待后台新结果。 */}
    }
  }

  /// 无缓存入口可提前结束等待，已恢复快照继续供本次启动使用。
  void _markUnavailable(Set<String> names) {
    if (_disposed) return;
    _unavailable.addAll(names.difference(_active.keys.toSet()));
    _progress.add(null);
  }

  /// 共用内容仍绑定调用 Client 的身份，避免跨兜底域接管网页。
  PaywallPlacement? _bind(PaywallPlacement? value, PaywallClient client) =>
      value == null
          ? null
          : PaywallPlacement(
              name: value.name,
              document: value.document,
              environment: value.environment,
              presentation: value.presentation,
              sessionPolicy: value.sessionPolicy,
              requestIdentity: value.requestIdentity,
              configurationSnapshot: value.configurationSnapshot,
              clientIdentity: client.identity,
              source: value.source,
              remoteDocument: value.remoteDocument);

  /// 最后一个宿主释放后取消离线等待，下载晚到结果不再写索引。
  void _detach(PaywallClient client, String key) {
    _clients.remove(client);
    if (_clients.isNotEmpty) return;
    _disposed = true;
    _cancelled.complete();
    attribution.dispose();
    _progress.add(null);
    unawaited(_progress.close());
    _sessions.remove(key);
  }

  /// 只记录版本和点位状态，不将静默更新结果弹给用户。
  void _trace(String event, String detail) => WebPaywallDiagnostics.log(
      configuration.runtimeEnvironment.name,
      event,
      'query=$_diagnosticID $detail');
}
