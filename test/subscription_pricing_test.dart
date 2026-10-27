import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';

void main() {
  test(
      'first month quote round trips shared fixture without losing localization',
      () {
    final fixture = jsonDecode(
        File('protocol/subscription-pricing.example.json')
            .readAsStringSync()) as Map<String, dynamic>;
    final pricing = PaywallSubscriptionPricing.fromPayload(fixture);
    expect(pricing.toPayload(), fixture);
    expect(pricing.phases.first.billingCycleCount, 1);
    expect(pricing.phases.first.displayPrice, '7,99 €');
    expect(() => pricing.phases.clear(), throwsUnsupportedError);
  });
  test(
      'Google Play preserves free trials, multiple discounted cycles and prepaid plans',
      () {
    final trial = PaywallPricingPhase.fromGooglePlay(
        priceAmountMicros: 0,
        priceCurrencyCode: 'JPY',
        formattedPrice: '無料',
        billingPeriod: 'P7D',
        billingCycleCount: 1,
        recurrenceMode: 2);
    final discount = PaywallPricingPhase.fromGooglePlay(
        priceAmountMicros: 123456789,
        priceCurrencyCode: 'JPY',
        formattedPrice: '￥123',
        billingPeriod: 'P1M',
        billingCycleCount: 3,
        recurrenceMode: 2);
    final prepaid = PaywallPricingPhase.fromGooglePlay(
        priceAmountMicros: 900000000,
        priceCurrencyCode: 'JPY',
        formattedPrice: '￥900',
        billingPeriod: 'P1Y',
        billingCycleCount: 0,
        recurrenceMode: 3);
    expect(trial.priceAmount, '0.000000');
    expect(discount.priceAmount, '123.456789');
    expect(discount.billingCycleCount, 3);
    expect(prepaid.recurrenceMode, 'nonRecurring');
    final source = [trial, discount, prepaid];
    final pricing = PaywallSubscriptionPricing(phases: source);
    source.clear();
    expect(pricing.phases, hasLength(3));
  });
  test('unknown legacy fields stay absent, invalid monetary data is rejected',
      () {
    const product = PaywallStoreProduct(
        productRef: 'monthly',
        storeProductId: 'monthly',
        title: '',
        displayPrice: '€19.99',
        disclosure: 'monthly');
    expect(product.subscriptionPricing, isNull);
    final valid = <String, dynamic>{
      'priceAmount': '19.99',
      'currencyCode': 'EUR',
      'displayPrice': '19,99 €',
      'billingPeriod': 'P1M',
      'billingCycleCount': 0,
      'recurrenceMode': 'infiniteRecurring'
    };
    for (final patch in [
      {'priceAmount': '-1'},
      {'priceAmount': '1,99'},
      {'currencyCode': '€'},
      {'billingPeriod': 'month'},
      {'billingCycleCount': 1},
      {'recurrenceMode': 'unknown'},
    ]) {
      expect(() => PaywallPricingPhase.fromPayload({...valid, ...patch}),
          throwsFormatException);
    }
    final regular = PaywallPricingPhase.fromPayload(valid);
    expect(() => PaywallSubscriptionPricing(phases: [regular, regular]),
        throwsFormatException);
    expect(() => PaywallSubscriptionPricing(phases: []), throwsFormatException);
    final usd =
        PaywallPricingPhase.fromPayload({...valid, 'currencyCode': 'USD'});
    final intro = PaywallPricingPhase.fromPayload({
      ...valid,
      'recurrenceMode': 'finiteRecurring',
      'billingCycleCount': 1
    });
    expect(() => PaywallSubscriptionPricing(phases: [intro, usd]),
        throwsFormatException);
  });
}
