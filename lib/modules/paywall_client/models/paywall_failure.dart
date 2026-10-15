/// 页面、商品和资格失败分开分类，避免错误回退或污染包健康状态。
enum PaywallFailure implements Exception {
  configuration,
  missingPlacement,
  disabled,
  resource,
  bridge,
  renderTimeout,
  productsUnavailable,
  cancelled,
  eligibility;

  bool get permitsFallback => const {
        configuration,
        missingPlacement,
        resource,
        bridge,
        renderTimeout
      }.contains(this);
  bool get invalidatesPackage => this == resource || this == bridge;
}
