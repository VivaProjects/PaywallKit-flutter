/// 可选交易策略；旧桥默认要求商品并允许交易，不增加宿主框架依赖。
abstract interface class PaywallStoreActionPolicy {
  bool get requiresStoreProducts;
  bool get allowsStoreActions;
}
