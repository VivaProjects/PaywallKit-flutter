part of 'paywall_query_runtime.dart';

/// 更新诊断与弱网策略不改变启动快照的所有权。
extension PaywallQueryUpdate on PaywallQueryRuntime {
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
      PaywallConfigurationRequest request) async {
    final old = _active[name];
    final changed = old == null ||
        old.presentation.name != mode ||
        PaywallStorage.digest(WebPaywallPackage.identity(
                old.remoteDocument ?? old.document)) !=
            PaywallStorage.digest(WebPaywallPackage.identity(doc));
    final saved = await _accept(name, doc, mode, request);
    if (!_disposed && changed && saved) _updatedPlacements++;
  }

  /// 宿主诊断异常不破坏下载或快照；取消和日志关闭时不通知。
  void _report(PaywallQueryUpdateDiagnostic diagnostic) {
    if (_disposed ||
        !PaywallLogging.isEnabled(configuration.runtimeEnvironment.name))
      return;
    try {
      configuration.onUpdateDiagnostic?.call(diagnostic);
    } catch (error) {
      _trace('query.diagnostic_failed', '$error');
    }
  }
}
