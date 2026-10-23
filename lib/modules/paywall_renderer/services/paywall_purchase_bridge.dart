import '../models/paywall_store_product.dart';

enum PaywallPurchaseResult { succeeded, cancelled, pending, noEntitlement }

/// 宿主用 StoreKit 或 Google Play 实现；JSON 不控制金额、资格或交易结果。
abstract interface class PaywallPurchaseBridge {
  Future<List<PaywallStoreProduct>> products(
      List<String> references, String storefrontGroup);
  Future<PaywallPurchaseResult> purchase(PaywallStoreProduct product);
  Future<PaywallPurchaseResult> restore();
}

/// 可选能力声明；未实现的历史桥接仍要求真实商品并允许交易。
abstract interface class PaywallPurchaseCapabilities {
  bool get requiresStoreProducts;
  bool get allowsStoreActions;
}

/// 兼容既有桥接，只有显式声明才允许空商品完成首屏。
extension PaywallPurchaseCapabilityDefaults on PaywallPurchaseBridge {
  bool get requiresStoreProducts => this is PaywallPurchaseCapabilities
      ? (this as PaywallPurchaseCapabilities).requiresStoreProducts
      : true;
  bool get allowsStoreActions => this is PaywallPurchaseCapabilities
      ? (this as PaywallPurchaseCapabilities).allowsStoreActions
      : true;
}
