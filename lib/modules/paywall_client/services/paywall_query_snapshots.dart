part of 'paywall_query_runtime.dart';

/// 启动快照恢复、持久化及历史迁移与网络任务调度分离。
extension PaywallQuerySnapshots on PaywallQueryRuntime {
  /// 环境、端点、版本及稳定适配条件隔离；国家和渠道保留在原请求中。
  Future<void> _restore() async {
    final env = await _environment();
    final scope = jsonEncode([
      configuration.cacheScope,
      configuration.endpoint.toString(),
      env.appVersion,
      env.deviceModel,
      env.language
    ]);
    final root = await storage.folder('query_snapshots', scope);
    _archive = _makeArchive(() async => root);
    _index = File('${root.path}/index.json');
    _hasIndex = await _index.exists();
    try {
      final saved = await PaywallStorage.read(_index);
      if (saved['version'] != 1 || saved['records'] is! Map) return;
      final records = Map<String, dynamic>.from(saved['records'] as Map);
      if (records.length > 100) return;
      _records.addAll(records);
      for (final name in records.keys) {
        if (!configuration.placements.values.contains(name)) continue;
        await _restoreRecord(name, records[name], env);
      }
    } catch (_) {/* 无索引时由唯一后台查询补齐。 */}
    _launchFallback = _active[configuration.fallback?.placement];
    await _prune();
  }

  /// 各点位独立复验完整资源，单点损坏不影响其他启动版本。
  Future<void> _restoreRecord(
      String name, Object? raw, WebPaywallEnvironment env) async {
    try {
      final record = Map<String, dynamic>.from(raw as Map);
      _validateRecord(record);
      final doc = await _archive
          .open(Map<String, dynamic>.from(record['document'] as Map));
      _checkActive();
      _leases.add(WebPaywallResourceLease(doc.localDirectory!, () {}));
      _activeRecords[name] = record;
      _active[name] = PaywallPlacement(
          name: name,
          document: doc,
          environment: env.forPlacement(name),
          presentation: WebPaywallPresentation.values
              .byName(record['presentation'] as String),
          requestIdentity: record['requestIdentity'] as String,
          clientIdentity: client.identity,
          source: 'disk',
          remoteDocument: _archive
              .document(Map<String, dynamic>.from(record['document'] as Map)),
          configurationSnapshot: _recordConfiguration(name, record));
    } catch (_) {/* 单个坏包不影响其他启动点位。 */}
  }

  /// 旧缓存只迁移确切请求身份与完整磁盘资源，不能靠下载伪造启动缓存。
  Future<void> _migrateLegacy(PaywallConfigurationRequest request) async {
    if (_hasIndex) return;
    try {
      final old = await client.configuration.cached(request);
      for (final name in old.placements.keys) {
        if (!configuration.placements.values.contains(name)) continue;
        final document = old.documentForPlacement(name);
        if (document == null) continue;
        try {
          final lease = await response.loader.resourceCache
              .cachedPackage(document, configuration.runtimeEnvironment.name);
          try {
            await _accept(name, document.withLocalDirectory(lease.directory),
                old.presentations[name]!, request);
          } finally {
            lease.release();
          }
        } catch (_) {/* 不完整旧包继续等待后台查询。 */}
      }
    } catch (_) {/* 没有确切请求缓存时不从其他请求迁移。 */}
  }

  /// 恢复原请求身份以防索引串用，价格与权益不进入持久记录。
  void _validateRecord(Map<String, dynamic> record) {
    final env = Map<String, dynamic>.from(record['environment'] as Map);
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
    if (env['runtimeEnvironment'] != configuration.runtimeEnvironment.name ||
        request.identity(configuration.cacheScope) !=
            record['requestIdentity']) {
      throw const FormatException('Invalid snapshot request identity');
    }
  }

  /// 保留通用 refresh 返回类型，查询式入口仍只触发一次后台任务。
  Future<WebPaywallConfiguration> refresh() async {
    await prepare();
    final pages = <String, dynamic>{};
    final placements = <String, String>{};
    final modes = <String, String>{};
    for (final entry in _activeRecords.entries) {
      final record = entry.value as Map;
      final document = record['document'] as Map;
      final id = document['documentId'] as String;
      if (pages.containsKey(id) &&
          jsonEncode(pages[id]) != jsonEncode(document)) {
        throw StateError(
            'Mixed launch revisions; use resolve(placement) for per-placement snapshots');
      }
      pages[id] = document;
      placements[entry.key] = id;
      modes[entry.key] = record['presentation'] as String;
    }
    return WebPaywallConfiguration.parse(
        jsonEncode({
          'version': 1,
          'placements': placements,
          'presentations': modes,
          'paywalls': pages,
          'preload': [],
          'sessions': {}
        }),
        allowedOrigins: configuration.allowedOrigins,
        catalogs: {'default': catalog()},
        developmentHTTPOrigin: configuration.developmentHTTPOrigin);
  }

  /// 索引原子替换，资源目录与当前已持有会话独立保留。
  Future<void> _save() {
    // 固定本次索引内容，再串行提交，防止两个完成包的写入乱序。
    final snapshot =
        jsonDecode(jsonEncode({'version': 1, 'records': _records}));
    final task = _saving.then((_) =>
        PaywallStorage.write(_index, snapshot, isCurrent: () => !_disposed));
    _saving = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  /// 冷启动快照兜底不等待网络，也不采用本次后台才新增的版本。
  Future<PaywallPlacement?> fallbackAtLaunch() async {
    await (_initializing ??= _restore());
    _checkActive();
    return _launchFallback;
  }

  /// 单点位配置保存原始发布身份，供成功版本归档和历史复验使用。
  String _recordConfiguration(String name, Map record) {
    final document = record['document'] as Map;
    final id = document['documentId'];
    return jsonEncode({
      'version': 1,
      'placements': {name: id},
      'presentations': {name: record['presentation']},
      'paywalls': {id: document},
      'preload': [],
      'sessions': {}
    });
  }

  /// 只在恢复时回收未被索引或其他会话租约持有的历史包。
  Future<void> _prune() async {
    final packages = Directory('${_index.parent.path}/packages');
    final kept = _records.values
        .whereType<Map>()
        .map((record) => PaywallStorage.digest(record['document']))
        .toSet();
    if (!await packages.exists()) return;
    await for (final entry in packages.list(followLinks: false)) {
      if (entry is Directory &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.path.split('/').last) &&
          !kept.contains(entry.path.split('/').last) &&
          !WebPaywallResourceLease.isInUse(entry)) {
        try {
          await entry.delete(recursive: true);
        } catch (_) {/* 下次恢复重试清理。 */}
      }
    }
  }
}
