import '../models/paywall_failure.dart';
import '../models/paywall_placement.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import 'paywall_client.dart';
import 'paywall_local_package_store.dart';

/// 一次展示只向前推进：当前版本、同页旧版、本地更新包、内置包。
class PaywallFallbackContext {
  PaywallFallbackContext(
      {required this.client,
      required this.placement,
      this.timeout = const Duration(seconds: 12)})
      : deadline = DateTime.now().add(timeout) {
    store = client.localPackages;
    local = store?.placement == placement;
  }
  final PaywallClient client;
  final String placement;
  final Duration timeout;
  DateTime deadline;
  PaywallLocalPackageStore? store;
  PaywallPlacement? current;
  PaywallPlacement? selected;
  PaywallFailure? reason;
  bool local = false, bundledOnly = false, triedPrevious = false;
  bool get usesHistory => client.previousVersionPlacements.contains(placement);
  Duration get remaining => deadline.difference(DateTime.now());

  /// 第一次解析点位，专属本地入口完全绕过配置网络请求。
  Future<PaywallPlacement> resolve() async {
    await store?.initialize();
    _checkDisabled();
    if (local) return _local();
    final value = await client.resolve(placement);
    store = client.localPackages;
    await store?.initialize();
    _checkDisabled();
    if (value == null) throw PaywallFailure.missingPlacement;
    current = selected = value;
    return value;
  }

  /// 回退不处理取消和资格错误，商店不可用只在显式历史范围内回退。
  Future<PaywallPlacement?> advance(PaywallFailure failure) async {
    _checkDisabled();
    if (!(failure.permitsFallback ||
            usesHistory && failure == PaywallFailure.productsUnavailable) ||
        store == null) return null;
    reason ??= failure;
    if (!local) {
      if (!store!.fallbackPlacements.contains(placement)) return null;
      if (usesHistory && !triedPrevious && current != null) {
        triedPrevious = true;
        try {
          final previous = await client.previousPlacement(current!);
          if (previous != null) {
            retryDeadline();
            return selected = _withReason(previous);
          }
        } on PaywallFailure catch (error) {
          if (error == PaywallFailure.disabled) rethrow;
        } catch (_) {/* 损坏历史不阻断最后的内置兜底。 */}
      }
      local = true;
    } else {
      if (bundledOnly ||
          selected?.source != 'update' &&
              !(client.usesLaunchSnapshot && selected?.source == 'disk'))
        return null;
      bundledOnly = true;
    }
    retryDeadline();
    return _local();
  }

  /// 本地包整体替换页面商品绑定，同时保留真实入口用于 H5 与日志。
  Future<PaywallPlacement> _local() async {
    _checkDisabled();
    if (!bundledOnly && client.queryFallbackAtLaunch != null) {
      final cached = await client.queryFallbackAtLaunch!();
      if (cached != null) return selected = _withReason(cached);
    }
    final value = await store!.selection(bundledOnly: bundledOnly);
    final environment = await client.currentEnvironment();
    if (environment.runtimeEnvironment.name != store!.archive.environment)
      throw PaywallFailure.configuration;
    return selected = PaywallPlacement(
        name: placement,
        document: value.document,
        environment: environment.forPlacement(placement),
        presentation: WebPaywallPresentation.fullScreen,
        clientIdentity: client.identity,
        source: value.source,
        fallbackReason: reason?.name);
  }

  /// 历史保留原配置的权限，不借用当前版本的商品规则。
  PaywallPlacement _withReason(PaywallPlacement value) => PaywallPlacement(
      name: placement,
      document: value.document,
      environment: value.environment,
      presentation: value.presentation,
      sessionPolicy: value.sessionPolicy,
      clientIdentity: client.identity,
      source: value.source,
      fallbackReason: reason?.name);

  /// 每个候选各有总准备期限，手动重试继续当前分支。
  void retryDeadline() {
    deadline = DateTime.now().add(timeout);
  }

  /// 显式关闭始终优先，网络失败不能绕过已生效开关。
  void _checkDisabled() {
    if (client.isPlacementDisabled(placement)) throw PaywallFailure.disabled;
  }
}
