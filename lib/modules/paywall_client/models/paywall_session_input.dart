import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_custom.dart';

/// 宿主准备资格和交易桥，页面绑定与实际入口仍由 SDK 固定。
class PaywallSessionInput {
  PaywallSessionInput(
      {required this.document,
      required this.purchaseBridge,
      required this.environment,
      Map<String, dynamic> custom = const {},
      this.allowsDismiss = true})
      : custom = freezeWebPaywallCustom(custom);
  final WebPaywallDocument document;
  final PaywallPurchaseBridge purchaseBridge;
  final WebPaywallEnvironment environment;
  final Map<String, dynamic> custom;
  final bool allowsDismiss;
}
