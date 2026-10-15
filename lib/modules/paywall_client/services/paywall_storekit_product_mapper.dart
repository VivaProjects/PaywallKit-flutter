import 'package:flutter/services.dart';
import '../../paywall_renderer/models/paywall_store_product.dart';

/// iOS 的可选默认商店映射器，宿主仍可使用自己的本地化披露实现。
class PaywallStoreKitProductMapper {
  /// StoreKit 2 查询真实商店价格和优惠资格，不提供购买或验单逻辑。
  static Future<List<PaywallStoreProduct>> products(List<String> productRefs,
      {bool includesDailyPrice = false}) async {
    if (productRefs.isEmpty ||
        productRefs.length > 100 ||
        productRefs.toSet().length != productRefs.length ||
        productRefs.any((ref) => ref.isEmpty))
      throw const FormatException('Invalid product references');
    final values = await const MethodChannel('native_paywall/resources')
        .invokeListMethod<dynamic>('storeProducts', {
      'productRefs': productRefs,
      'includesDailyPrice': includesDailyPrice,
    });
    return [
      for (final value in values ?? [])
        _product(Map<String, dynamic>.from(value as Map))
    ];
  }

  /// 保留原生模型中的标题但不注入 H5，网页仍使用自己的 content.json。
  static PaywallStoreProduct _product(Map<String, dynamic> value) =>
      PaywallStoreProduct(
          productRef: value['productRef'] as String,
          storeProductId: value['storeProductId'] as String,
          title: value['title'] as String,
          displayPrice: value['displayPrice'] as String,
          disclosure: value['disclosure'] as String,
          periodText: value['periodText'] as String?,
          dailyPriceText: value['dailyPriceText'] as String?,
          introductoryPriceText: value['introductoryPriceText'] as String?,
          isEligibleForFreeTrial: value['isEligibleForFreeTrial'] as bool?);
}
