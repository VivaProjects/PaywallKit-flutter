import '../../../paywall_renderer/models/paywall_store_product.dart';
import '../../../paywall_renderer/models/paywall_pricing_phase.dart';
import '../../../paywall_renderer/models/paywall_subscription_pricing.dart';

/// SDK 内部选中的 Play 方案；令牌不属于 H5 商品模型。
class GooglePlayQuote {
  GooglePlayQuote._(this.product, this.quoteId, this.offerToken);
  final PaywallStoreProduct product;
  final String quoteId, offerToken;

  /// 使用 Play 返回的可用优惠；多基础套餐拒绝猜测，同套餐多优惠按 ID 固定排序。
  factory GooglePlayQuote.fromPayload(Map<String, dynamic> value) {
    final selected = _selectOffer(value);
    final phases = _phases(selected);
    final pricing = PaywallSubscriptionPricing(phases: phases);
    final regular = phases.last;
    final hasOffer = selected['offerId'] != null;
    if ((!hasOffer && phases.length != 1) ||
        (hasOffer &&
            (phases.length < 2 ||
                regular.recurrenceMode != 'infiniteRecurring'))) {
      throw const FormatException('Unsupported subscription offer phases');
    }
    final id = value['productId'] as String;
    final token = selected['offerToken'] as String,
        quote = value['quoteId'] as String;
    if (id.isEmpty || token.isEmpty || quote.isEmpty)
      throw const FormatException('Invalid store quote');
    return GooglePlayQuote._(
        PaywallStoreProduct(
          productRef: id,
          storeProductId: id,
          title: value['title'] as String,
          displayPrice: regular.displayPrice,
          disclosure: _disclosure(phases),
          periodText: regular.billingPeriod,
          subscriptionPricing: pricing,
          introductoryPriceText: hasOffer ? phases.first.displayPrice : null,
          isEligibleForFreeTrial: hasOffer &&
              RegExp(r'^0(?:\.0+)?$').hasMatch(phases.first.priceAmount),
        ),
        quote,
        token);
  }

  /// 自动选用商店返回的优惠，基础套餐不唯一时要求修正商品配置。
  static Map<String, dynamic> _selectOffer(Map<String, dynamic> value) {
    final offers = (value['offers'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final bases = offers.map((e) => e['basePlanId']).toSet();
    if (offers.isEmpty ||
        bases.length != 1 ||
        bases.single is! String ||
        (bases.single as String).isEmpty) {
      throw const FormatException(
          'Subscription must have one unambiguous base plan');
    }
    // Play 已过滤其管理的资格。开发者自定义资格的优惠不属于默认桥支持范围。
    offers.sort((a, b) {
      final aOffer = a['offerId'] as String?, bOffer = b['offerId'] as String?;
      if ((aOffer == null) != (bOffer == null)) return aOffer == null ? 1 : -1;
      return (aOffer ?? '').compareTo(bOffer ?? '');
    });
    return offers.first;
  }

  /// 以微单位整数转换价格，拒绝未知周期和不完整阶段。
  static List<PaywallPricingPhase> _phases(Map<String, dynamic> offer) => [
        for (final item in offer['phases'] as List)
          PaywallPricingPhase.fromGooglePlay(
            priceAmountMicros: item['priceAmountMicros'] as int,
            priceCurrencyCode: item['priceCurrencyCode'] as String,
            formattedPrice: item['formattedPrice'] as String,
            billingPeriod: item['billingPeriod'] as String,
            billingCycleCount: item['billingCycleCount'] as int,
            recurrenceMode: item['recurrenceMode'] as int,
          ),
      ];

  /// 兼容旧 H5 的披露字段；新页面用结构化数据和自己的本地化文案。
  static String _disclosure(List<PaywallPricingPhase> phases) =>
      phases.map((phase) {
        final price = '${phase.displayPrice} / ${phase.billingPeriod}';
        if (phase.recurrenceMode == 'finiteRecurring')
          return '$price for ${phase.billingCycleCount} periods';
        return phase.recurrenceMode == 'infiniteRecurring'
            ? '$price, automatically renews'
            : '$price, does not renew';
      }).join(', then ');
}
