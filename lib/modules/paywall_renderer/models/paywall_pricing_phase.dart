/// 商店收费阶段；金额使用十进制字符串，不从格式化价格反向解析。
class PaywallPricingPhase {
  /// 校验两端共用的金额、币种、周期和续订语义。
  PaywallPricingPhase(
      {required this.priceAmount,
      required this.currencyCode,
      required this.displayPrice,
      required this.billingPeriod,
      required this.billingCycleCount,
      required this.recurrenceMode}) {
    if (!RegExp(r'^(0|[1-9][0-9]*)(\.[0-9]+)?$').hasMatch(priceAmount) ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currencyCode) ||
        displayPrice.trim().isEmpty ||
        !RegExp(r'^P[1-9][0-9]*[DWMY]$').hasMatch(billingPeriod) ||
        !{'finiteRecurring', 'infiniteRecurring', 'nonRecurring'}
            .contains(recurrenceMode) ||
        (recurrenceMode == 'finiteRecurring'
            ? billingCycleCount <= 0
            : billingCycleCount != 0)) {
      throw const FormatException('Invalid pricing phase');
    }
  }
  final String priceAmount,
      currencyCode,
      displayPrice,
      billingPeriod,
      recurrenceMode;
  final int billingCycleCount;

  /// 将原生桥接字段恢复为受校验的不可变收费阶段。
  factory PaywallPricingPhase.fromPayload(Map<String, dynamic> value) =>
      PaywallPricingPhase(
          priceAmount: value['priceAmount'] as String,
          currencyCode: value['currencyCode'] as String,
          displayPrice: value['displayPrice'] as String,
          billingPeriod: value['billingPeriod'] as String,
          billingCycleCount: value['billingCycleCount'] as int,
          recurrenceMode: value['recurrenceMode'] as String);

  /// 将 Google Play 选定方案的单个阶段转换为共有数据；资格和 offerToken 由宿主管理。
  factory PaywallPricingPhase.fromGooglePlay(
      {required int priceAmountMicros,
      required String priceCurrencyCode,
      required String formattedPrice,
      required String billingPeriod,
      required int billingCycleCount,
      required int recurrenceMode}) {
    if (priceAmountMicros < 0) throw const FormatException('Negative price');
    final units = priceAmountMicros ~/ 1000000;
    final fraction = (priceAmountMicros % 1000000).toString().padLeft(6, '0');
    final mode = {
      1: 'infiniteRecurring',
      2: 'finiteRecurring',
      3: 'nonRecurring'
    }[recurrenceMode];
    if (mode == null) throw const FormatException('Unknown recurrence mode');
    return PaywallPricingPhase(
        priceAmount: '$units.$fraction',
        currencyCode: priceCurrencyCode,
        displayPrice: formattedPrice,
        billingPeriod: billingPeriod,
        billingCycleCount: billingCycleCount,
        recurrenceMode: mode);
  }

  /// 仅导出价格及计费条件，不暴露平台商品标题和购买令牌。
  Map<String, dynamic> toPayload() => {
        'priceAmount': priceAmount,
        'currencyCode': currencyCode,
        'displayPrice': displayPrice,
        'billingPeriod': billingPeriod,
        'billingCycleCount': billingCycleCount,
        'recurrenceMode': recurrenceMode,
      };
}
