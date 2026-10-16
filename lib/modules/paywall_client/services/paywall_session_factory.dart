import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import '../../web_paywall/controllers/web_paywall_controller.dart';
import '../../web_paywall/services/web_paywall_preloader.dart';
import '../models/paywall_placement.dart';

/// 将解析结果转换为独立 H5 会话；调用方显式持有并交给视图。
class PaywallSessionFactory {
  PaywallSessionFactory(
      {required this.placement,
      required this.bridge,
      required this.dismiss,
      required this.openLegal,
      this.storefrontGroup = 'default',
      this.custom = const {},
      this.allowsDismiss = true,
      this.onPurchaseResult,
      this.onRestoreResult,
      this.preloader});
  final PaywallPlacement placement;
  final PaywallPurchaseBridge bridge;
  final String storefrontGroup;
  final Map<String, dynamic> custom;
  final bool allowsDismiss;
  final void Function() dismiss;
  final void Function(String) openLegal;
  final void Function(String, PaywallPurchaseResult)? onPurchaseResult;
  final void Function(PaywallPurchaseResult)? onRestoreResult;
  final WebPaywallPreloader? preloader;

  /// 用真实入口点位与解析时冻结的环境创建会话，不允许页面改写路由。
  WebPaywallController _createController() => WebPaywallController(
      document: placement.document,
      environment: placement.environment,
      storefrontGroup: storefrontGroup,
      custom: custom,
      bridge: bridge,
      sessionPolicy: placement.sessionPolicy,
      allowsDismiss:
          allowsDismiss && placement.presentation.name != 'halfSheetLocked',
      dismiss: dismiss,
      openLegal: openLegal,
      onPurchaseResult: onPurchaseResult,
      onRestoreResult: onRestoreResult);

  /// 完整身份一致才接管预加载；返回值由 WebPaywallView 默认负责释放。
  WebPaywallController createController() {
    final fresh = _createController();
    final cached = preloader?.take();
    if (cached?.canReuseFor(fresh) == true) {
      fresh.dispose();
      return cached!;
    }
    cached?.dispose();
    return fresh;
  }
}
