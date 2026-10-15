enum PaywallEventName {
  paywallConfigFallback('paywall_config_fallback'),
  paywallImpression('paywall_impression'),
  paywallProductSelected('paywall_product_selected'),
  paywallPurchaseStarted('paywall_purchase_started'),
  paywallPurchaseResult('paywall_purchase_result'),
  paywallRestoreResult('paywall_restore_result'),
  paywallRenderError('paywall_render_error'),
  paywallDismissed('paywall_dismissed');

  const PaywallEventName(this.wireName);
  final String wireName;
}

class PaywallEvent {
  PaywallEvent(this.name, Map<String, Object> context)
      : context = Map.unmodifiable(context);
  final PaywallEventName name;
  final Map<String, Object> context;
}
