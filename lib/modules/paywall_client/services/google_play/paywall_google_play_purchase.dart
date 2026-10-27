/// 仅交给宿主验单的交易证据，不向 H5 注入 token 或商店原始 JSON。
class PaywallGooglePlayPurchase {
  /// 固定交易快照，便于宿主验证商品归属、有效期和账户权益。
  PaywallGooglePlayPurchase.fromPayload(Map<String, dynamic> value)
      : productIds = List<String>.unmodifiable(
            (value['productIds'] as List).cast<String>()),
        purchaseToken = value['purchaseToken'] as String,
        originalJson = value['originalJson'] as String,
        signature = value['signature'] as String,
        acknowledged = value['acknowledged'] as bool,
        pending = value['pending'] as bool;
  final List<String> productIds;
  final String purchaseToken, originalJson, signature;
  final bool acknowledged, pending;
}
