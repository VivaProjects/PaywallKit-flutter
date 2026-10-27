import 'paywall_pricing_phase.dart';

/// 当前实际购买方案的完整收费阶段；缺省表示旧宿主未提供，不能推断无资格。
class PaywallSubscriptionPricing {
  /// 固定报价快照，防止宿主后续修改列表导致预加载缓存沿用旧价格。
  PaywallSubscriptionPricing({required List<PaywallPricingPhase> phases})
      : phases = List.unmodifiable(phases) {
    if (phases.isEmpty ||
        phases.map((p) => p.currencyCode).toSet().length != 1 ||
        phases
            .take(phases.length - 1)
            .any((p) => p.recurrenceMode != 'finiteRecurring')) {
      throw const FormatException('Invalid subscription pricing');
    }
  }
  final List<PaywallPricingPhase> phases;

  /// 接收 StoreKit 通道返回的完整方案，格式错误时拒绝使用。
  factory PaywallSubscriptionPricing.fromPayload(Map<String, dynamic> value) =>
      PaywallSubscriptionPricing(phases: [
        for (final phase in value['phases'] as List)
          PaywallPricingPhase.fromPayload(
              Map<String, dynamic>.from(phase as Map)),
      ]);

  /// 输出统一 H5 协议；阶段顺序与原生实际购买方案一致。
  Map<String, dynamic> toPayload() =>
      {'phases': phases.map((p) => p.toPayload()).toList()};
}
