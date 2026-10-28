import '../../web_paywall/models/web_paywall_resource_lease.dart';
import 'dart:io';
import '../../web_paywall/services/web_paywall_diagnostics.dart';
import 'dart:convert';
import '../models/paywall_configuration_request.dart';
import 'paywall_query_response.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../models/paywall_placement.dart';
import '../models/paywall_query_configuration.dart';
import 'paywall_package_archive.dart';
import 'paywall_query_archive_batch.dart';
import '../../web_paywall/services/web_paywall_resource_preparation.dart';
import 'paywall_storage.dart';

/// 点位索引只指向已归档完整包，与普通资源 LRU 隔离。
class PaywallQuerySnapshots {
  PaywallQuerySnapshots(this.configuration, this.catalog, this.storage,
      {bool Function()? isCurrent, this.archiveFactory})
      : _isCurrent = isCurrent ?? (() => true);
  final bool Function() _isCurrent;
  final PaywallQueryConfiguration configuration;
  final PaywallCatalog Function() catalog;
  final PaywallStorage storage;
  final PaywallPackageArchive Function(String scope)? archiveFactory;
  late final PaywallPackageArchive archive;
  late WebPaywallEnvironment _environment;
  Future<void>? _initializing;

  /// 当前设备适配参数与端点共同隔离磁盘缓存，保留旧格式的迁移入口。
  Future<void> _initialize() async {
    _environment = await configuration.environment();
    if (_environment.runtimeEnvironment != configuration.runtimeEnvironment) {
      throw const FormatException('Wrong snapshot environment');
    }
    final scope = jsonEncode([
      configuration.cacheScope,
      configuration.endpoint.toString(),
      _environment.appVersion,
      _environment.deviceModel,
      _environment.language,
      _environment.os,
      _environment.isPad,
    ]);
    archive = _archiveFor(scope);
  }

  /// 迁移读取使用相同来源约束，不允许缓存扩大宿主目录授权。
  PaywallPackageArchive _archiveFor(String scope) =>
      archiveFactory?.call(scope) ??
      PaywallPackageArchive(
        directory: () => storage.folder('query_snapshots', scope),
        environment: configuration.runtimeEnvironment.name,
        catalog: catalog,
        allowedOrigins: configuration.allowedOrigins,
        developmentHTTPOrigin: configuration.developmentHTTPOrigin,
      );
  final Map<String, dynamic> _records = {};
  Future<void> _serial = Future.value();
  bool hasIndex = false;

  Future<void>? _restoringIndex;
  final _restored = <String, Future<PaywallPlacement?>>{};
  final _openedPackages = <String, Future<WebPaywallDocument>>{};

  /// 冻结启动索引；只有元数据和旧版迁移完成后才允许后台更新。
  Future<void> _restoreIndex() async {
    await (_initializing ??= _initialize());
    if (!await (await _file()).exists()) await _migrateSnapshots();
    try {
      final data = await PaywallStorage.read(await _file());
      if (data['version'] != 1 ||
          data['environment'] != configuration.runtimeEnvironment.name) return;
      final records = Map<String, dynamic>.from(data['placements'] as Map);
      if (records.length > configuration.placements.length) return;
      _records.addAll(records);
      hasIndex = true;
    } catch (_) {/* 无有效索引时由后台查询补齐。 */}
  }

  /// 当前点位可独立恢复；所有调用者共用一次完整校验，坏包仍视为缺失。
  Future<PaywallPlacement?> restorePlacement(String name,
          {WebPaywallResourcePreparation? preparation}) =>
      _restored.putIfAbsent(name, () async {
        await (_restoringIndex ??= _restoreIndex());
        if (!_isCurrent() || !configuration.placements.containsValue(name)) {
          return null;
        }
        final record = _records[name];
        if (record == null) return null;
        try {
          return await _open(
              name, Map<String, dynamic>.from(record as Map), preparation);
        } catch (_) {/* 单个损坏快照等待后台补齐。 */}
        return null;
      });

  /// 按当前入口优先恢复，并逐点交付，不等待其他点位完成才发布缓存。
  Future<Map<String, PaywallPlacement>> restore({
    String? Function()? preferredPlacement,
    void Function(PaywallPlacement)? onPlacement,
  }) async {
    await (_restoringIndex ??= _restoreIndex());
    final result = <String, PaywallPlacement>{};
    final pending = _records.keys.toList();
    while (pending.isNotEmpty && _isCurrent()) {
      final preferred = preferredPlacement?.call();
      final name = pending.removeAt(
          pending.contains(preferred) ? pending.indexOf(preferred!) : 0);
      final value = await restorePlacement(name);
      if (!_isCurrent()) break;
      if (value != null) {
        result[name] = value;
        onPlacement?.call(value);
      }
    }
    return result;
  }

  /// 原始配置重新解析，索引不能扩大当前宿主允许的商品目录。
  Future<PaywallPlacement> _open(String name, Map<String, dynamic> record,
      WebPaywallResourcePreparation? preparation) async {
    final parsed = WebPaywallConfiguration.parse(
        record['configuration'] as String,
        allowedOrigins: configuration.allowedOrigins,
        catalogs: {'default': catalog()},
        developmentHTTPOrigin: configuration.developmentHTTPOrigin);
    final document = parsed.documentForPlacement(name);
    if (document == null)
      throw const FormatException('Missing snapshot placement');
    final identity = WebPaywallPackage.identity(document);
    final local = await _openedPackages.putIfAbsent(
        PaywallStorage.digest(identity),
        () => preparation == null
            ? archive.open(identity)
            : archive.openForPreparation(identity, preparation));
    final env = Map<String, dynamic>.from(record['environment'] as Map);
    if (env['runtimeEnvironment'] != configuration.runtimeEnvironment.name)
      throw const FormatException('Wrong environment');
    return PaywallPlacement(
        name: name,
        document: local,
        remoteDocument: document,
        environment: _environment.forPlacement(name),
        presentation: parsed.presentations[name]!,
        sessionPolicy: parsed.sessions[name],
        requestIdentity: record['requestIdentity'] as String,
        configurationSnapshot: parsed.source,
        source: 'launch_snapshot');
  }

  /// 旧独立 SDK 和 Android 快照只迁移当前环境的完整包，不触发网络。
  Future<void> _migrateSnapshots() async {
    final scopes = [
      jsonEncode([
        configuration.cacheScope,
        configuration.endpoint.toString(),
        _environment.appVersion,
        _environment.deviceModel,
        _environment.language,
      ]),
      configuration.cacheScope
    ];
    for (final scope in scopes) {
      final oldArchive = _archiveFor(scope);
      try {
        final data = await PaywallStorage.read(
            File('${(await oldArchive.directory()).path}/index.json'));
        if (!_isCurrent()) return;
        if (data['version'] != 1) continue;
        final records = data['records'] ?? data['placements'];
        if (records is! Map || records.length > 100) continue;
        for (final entry in records.entries) {
          if (!_isCurrent()) return;
          if (!configuration.placements.containsValue(entry.key) ||
              _records.containsKey(entry.key)) continue;
          try {
            await _migrateRecord(entry.key as String,
                Map<String, dynamic>.from(entry.value as Map), oldArchive);
          } catch (_) {/* 损坏或不匹配的旧包不迁移。 */}
        }
      } catch (_) {/* 旧版本未生成缓存时由后台查询补齐。 */}
    }
  }

  /// 比较稳定适配条件并重新校验完整资源，迁移后使用当前环境字段。
  Future<void> _migrateRecord(String name, Map<String, dynamic> record,
      PaywallPackageArchive oldArchive) async {
    final env = Map<String, dynamic>.from(record['environment'] as Map);
    final current = _environment.toPayload();
    for (final key in [
      'runtimeEnvironment',
      'appVersion',
      'deviceModel',
      'language'
    ]) {
      if (env[key] != current[key]) return;
    }
    for (final key in ['os', 'isPad']) {
      if (env.containsKey(key) && env[key] != current[key]) return;
    }
    String raw;
    if (record['configuration'] is String) {
      raw = record['configuration'] as String;
    } else {
      final request = PaywallConfigurationRequest(
          uri: configuration.endpoint,
          method: 'POST',
          body: record['requestBody'] as String,
          environment: WebPaywallEnvironment(
              os: env['os'] as String?,
              isPad: env['isPad'] as bool? ?? false,
              language: env['language'] as String,
              deviceModel: env['deviceModel'] as String,
              country: env['country'] as String,
              appVersion: env['appVersion'] as String,
              runtimeEnvironment: configuration.runtimeEnvironment));
      if (request.identity(configuration.cacheScope) !=
          record['requestIdentity']) return;
      final doc = oldArchive
          .document(Map<String, dynamic>.from(record['document'] as Map));
      raw = PaywallQueryResponse.configurationFor(
          name, doc, record['presentation'] as String);
    }
    final parsed = WebPaywallConfiguration.parse(raw,
        allowedOrigins: configuration.allowedOrigins,
        catalogs: {'default': catalog()},
        developmentHTTPOrigin: configuration.developmentHTTPOrigin);
    final doc = parsed.documentForPlacement(name);
    if (doc == null) return;
    final local = await oldArchive.open(WebPaywallPackage.identity(doc));
    await save(
        PaywallPlacement(
            name: name,
            document: local,
            environment: _environment.forPlacement(name),
            presentation: parsed.presentations[name]!,
            sessionPolicy: parsed.sessions[name],
            requestIdentity: record['requestIdentity'] as String,
            configurationSnapshot: raw),
        _isCurrent);
  }

  /// 下载与摘要验证成功后串行提交索引；失败不会先清除旧版本。
  Future<PaywallPlacement> save(
      PaywallPlacement value, bool Function() isCurrent,
      {WebPaywallResourceLease? resource,
      PaywallQueryArchiveBatch? batch}) async {
    final local = batch == null
        ? await archive.archive(value.document,
            isCurrent: isCurrent, resource: resource)
        : await batch.save(archive, value.document, isCurrent, resource);
    await _enqueue(() async {
      final records = {
        ..._records,
        value.name: {
          'configuration': value.configurationSnapshot,
          'requestIdentity': value.requestIdentity,
          'environment': value.environment.toPayload(),
        }
      };
      await _commit(records, isCurrent);
    });
    return PaywallPlacement(
        name: value.name,
        document: local,
        remoteDocument: value.remoteDocument ?? value.document,
        environment: value.environment,
        presentation: value.presentation,
        sessionPolicy: value.sessionPolicy,
        requestIdentity: value.requestIdentity,
        configurationSnapshot: value.configurationSnapshot,
        source: 'query_snapshot');
  }

  /// 只有合法响应的明确未命中集合才删除下次启动指针。
  Future<void> remove(Set<String> unmatched, bool Function() isCurrent) =>
      _enqueue(() async {
        final records = {..._records}
          ..removeWhere((key, _) => unmatched.contains(key));
        await _commit(records, isCurrent);
      });

  /// 完整索引原子替换后再更新内存，磁盘失败保留原指针。
  Future<void> _commit(
      Map<String, dynamic> records, bool Function() isCurrent) async {
    final file = await _file();
    await WebPaywallDiagnostics.measure(
        configuration.runtimeEnvironment.name,
        'snapshot.commit',
        () => PaywallStorage.write(
            file,
            {
              'version': 1,
              'environment': configuration.runtimeEnvironment.name,
              'placements': records
            },
            isCurrent: isCurrent),
        detail: 'placements=${records.length}');
    _records
      ..clear()
      ..addAll(records);
    hasIndex = true;
  }

  /// 同时完成的下载不会互相覆盖索引。
  Future<void> _enqueue(Future<void> Function() action) {
    final task = _serial.then((_) => action());
    _serial = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  /// 使用带环境的命名空间隔离索引与包，外部点位不参与路径拼接。
  Future<File> _file() async =>
      File('${(await archive.directory()).path}/index.json');
}
