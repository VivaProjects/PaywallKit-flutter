part of 'paywall_query_runtime.dart';

/// 更新诊断与弱网策略不改变启动快照的所有权。
extension PaywallQueryUpdate on PaywallQueryRuntime {
  /// 查询条件只采集一次，旧缓存迁移与联网使用同一个请求身份。
  Future<PaywallConfigurationRequest> _prepareRequest() async {
    final request = await _request();
    _source(configuration.cacheScope).validateRequest(request);
    return request;
  }

  /// 立即接住早到的失败；旧缓存迁移不能被网络响应阻塞。
  Future<(String?, Object?, StackTrace?)> _fetchUpdate(
      Future<PaywallConfigurationRequest> prepared) async {
    try {
      final request = await prepared;
      final raw = await WebPaywallDiagnostics.measure(
          configuration.runtimeEnvironment.name,
          'configuration.fetch',
          () => _retry(() async {
                _trace('configuration.request', 'method=${request.method}');
                return configuration.fetch?.call(request) ??
                    PaywallHttp.fetch(request.uri,
                        method: request.method, body: request.body);
              }, 'configuration'),
          detail: 'query=$_diagnosticID');
      _trace('configuration.response', 'bytes=${utf8.encode(raw).length}');
      return (raw, null, null);
    } catch (error, stack) {
      // 请求失败仍允许冻结后的精确身份旧缓存迁移，保持原有离线回退。
      return (null, error, stack);
    }
  }

  /// 所有重试共享取消信号，并在每次尝试前等待联网。
  Future<T> _retry<T>(Future<T> Function() operation, String stage) =>
      PaywallQueryRetry.run(
          operation: operation,
          online: _online,
          cancelled: _cancelled.future,
          isCancelled: () => _disposed,
          environment: configuration.runtimeEnvironment.name,
          stage: stage);

  /// 完整发布身份和展示方式均相同时，不把缓存校验误报为更新。
  Future<void> _acceptUpdate(String name, WebPaywallDocument doc, String mode,
      PaywallConfigurationRequest request,
      {WebPaywallResourceLease? resource,
      PaywallQueryArchiveBatch? batch}) async {
    final old = _active[name];
    final changed = old == null ||
        old.presentation.name != mode ||
        PaywallStorage.digest(WebPaywallPackage.identity(
                old.remoteDocument ?? old.document)) !=
            PaywallStorage.digest(WebPaywallPackage.identity(doc));
    final saved = await _accept(name, doc, mode, request,
        resource: resource, batch: batch);
    if (!_disposed && changed && saved) _updatedPlacements++;
  }

  /// 宿主诊断异常不破坏下载或快照；取消时不通知，打印开关不影响诊断结果。
  void _report(PaywallQueryUpdateDiagnostic diagnostic) {
    if (_disposed) return;
    try {
      configuration.onUpdateDiagnostic?.call(diagnostic);
    } catch (error) {
      _trace('query.diagnostic_failed', '$error');
    }
  }
}
