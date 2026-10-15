import '../models/paywall_store_product.dart';

enum PaywallPurchaseResult { succeeded, cancelled, pending, noEntitlement }

/// 宿主用 StoreKit 或 Google Play 实现；JSON 不控制金额、资格或交易结果。
abstract interface class PaywallPurchaseBridge {
  Future<List<PaywallStoreProduct>> products(
      List<String> references, String storefrontGroup);
  Future<PaywallPurchaseResult> purchase(PaywallStoreProduct product);
  Future<PaywallPurchaseResult> restore();
}
