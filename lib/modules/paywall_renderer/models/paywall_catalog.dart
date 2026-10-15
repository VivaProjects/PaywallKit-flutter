/// 由宿主固定商店引用，配置不包含实际商店交易参数。
class PaywallCatalog {
  PaywallCatalog(
      {required List<String> productRefs, required this.recommendedRef})
      : productRefs = List.unmodifiable(productRefs);
  final List<String> productRefs;
  final String recommendedRef;
}
