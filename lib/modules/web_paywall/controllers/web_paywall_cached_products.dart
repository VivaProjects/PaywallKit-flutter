part of 'web_paywall_controller.dart';

/// 缓存先展示时在后台核对完整报价，校验结束前保留购买门禁。
extension WebPaywallCachedProducts on WebPaywallController {
  /// 相同报价可继续使用旧表面；变化或失败交给 Flow 重建握手。
  Future<bool> validateRetainedProducts() async {
    final currentBridge = bridge;
    final refs = _requestedProductRefs;
    if (!_active || refs == null || _productsLoading) return false;
    _productsLoading = true;
    var unchanged = false;
    try {
      final values = await currentBridge.products(refs, storefrontGroup);
      if (!_active || !identical(bridge, currentBridge)) return false;
      final incoming = {
        for (final product in values)
          if (refs.contains(product.productRef)) product.productRef: product,
      };
      unchanged =
          _quoteIdentity(refs, _products) == _quoteIdentity(refs, incoming);
      if (unchanged) {
        _products
          ..clear()
          ..addAll(incoming);
      }
      return unchanged;
    } catch (_) {
      return false;
    } finally {
      // 变化时继续阻断旧价格购买，直到 Flow 销毁旧表面。
      if (_active && identical(bridge, currentBridge) && unchanged) {
        _productsLoading = false;
      }
    }
  }

  /// 按页面请求顺序比较所有展示字段，忽略商店返回顺序差异。
  String _quoteIdentity(
          List<String> refs, Map<String, PaywallStoreProduct> products) =>
      jsonEncode([
        for (final ref in refs)
          if (products[ref] case final product?)
            [
              product.productRef,
              product.storeProductId,
              product.title,
              product.displayPrice,
              product.disclosure,
              product.periodText,
              product.dailyPriceText,
              product.introductoryPriceText,
              product.isEligibleForFreeTrial,
              product.subscriptionPricing?.toPayload(),
            ]
      ]);
}
