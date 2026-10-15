class PaywallStoreProduct {
  const PaywallStoreProduct(
      {required this.productRef,
      required this.storeProductId,
      required this.title,
      required this.displayPrice,
      required this.disclosure,
      this.periodText,
      this.dailyPriceText,
      this.introductoryPriceText,
      this.isEligibleForFreeTrial});
  final String productRef, storeProductId, title, displayPrice, disclosure;

  /// 宿主确认的免费试用资格；缺省时 H5 不展示试用承诺。
  final bool? isEligibleForFreeTrial;
  final String? periodText, dailyPriceText, introductoryPriceText;
}
