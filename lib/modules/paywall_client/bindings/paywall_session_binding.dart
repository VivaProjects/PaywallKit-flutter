import 'package:get/get.dart';
import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import '../../web_paywall/controllers/web_paywall_controller.dart';
import '../../web_paywall/services/web_paywall_preloader.dart';
import '../models/paywall_placement.dart';

/// 将解析结果注入既有 H5 视图，注册仅在路由 Binding 内发生。
class PaywallSessionBinding extends Bindings {
  PaywallSessionBinding(
      {required this.sessionTag,
      required this.placement,
      required this.bridge,
      required this.dismiss,
      required this.openLegal,
      this.storefrontGroup = 'default',
      this.custom = const {},
      this.allowsDismiss = true,
      this.onPurchaseResult,
      this.onRestoreResult,
      this.preloader});
  final String sessionTag;
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
  WebPaywallController createController() => WebPaywallController(
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

  /// 预加载身份必须与当前完整绑定匹配，挂载后由 GetX 释放。
  @override
  void dependencies() {
    Get.lazyPut<WebPaywallController>(() {
      final fresh = createController();
      final cached = preloader?.take();
      if (cached?.canReuseFor(fresh) == true) return cached!;
      cached?.destroyPreload();
      return fresh;
    }, tag: sessionTag);
  }
}
