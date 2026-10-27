import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';

Map<String, dynamic> phase(int amount,
        {int count = 0, int mode = 1, String period = 'P1M'}) =>
    {
      'priceAmountMicros': amount,
      'priceCurrencyCode': 'EUR',
      'formattedPrice': amount == 0 ? '0,00 €' : '${amount ~/ 1000000},99 €',
      'billingPeriod': period,
      'billingCycleCount': count,
      'recurrenceMode': mode,
    };
Map<String, dynamic> offer(String? id,
        {String base = 'monthly', bool trial = false}) =>
    {
      'basePlanId': base,
      'offerId': id,
      'offerToken': id ?? 'regular-token',
      'phases': [
        if (id != null) phase(trial ? 0 : 7990000, count: 1, mode: 2),
        phase(19990000)
      ],
    };
Map<String, dynamic> product(
        {bool discounted = true,
        bool trial = false,
        String quote = 'quote-1'}) =>
    {
      'productId': 'monthly',
      'title': 'Store title',
      'quoteId': quote,
      'offers': [
        offer(null),
        if (discounted) offer('intro-token', trial: trial)
      ],
    };
Map<String, dynamic> receipt(
        {bool pending = false, bool acknowledged = false}) =>
    {
      'productIds': ['monthly'],
      'purchaseToken': 'purchase-token',
      'originalJson': '{}',
      'signature': 'signature',
      'pending': pending,
      'acknowledged': acknowledged,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('native_paywall/resources');
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) respond;
  late PaywallGooglePlayPurchaseBridge bridge;
  late List<String> events;
  setUp(() {
    calls = [];
    events = [];
    respond = (call) async => switch (call.method) {
          'googlePlayProducts' => [product()],
          'googlePlayPurchase' => receipt(),
          'googlePlayRestore' => [receipt()],
          _ => null,
        };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'googlePlayAcknowledge') events.add('ack');
      return respond(call);
    });
    bridge = PaywallGooglePlayPurchaseBridge(verifyPurchase: (purchase) async {
      events.add('verify');
      expect(purchase.purchaseToken, 'purchase-token');
      return true;
    });
  });
  tearDown(() async {
    await bridge.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
      'one product automatically selects eligible intro and purchases exact displayed quote',
      () async {
    final item = (await bridge.products(['monthly'], 'any-placement')).single;
    expect(item.subscriptionPricing!.phases, hasLength(2));
    expect(item.introductoryPriceText, '7,99 €');
    expect(item.displayPrice, '19,99 €');
    expect(item.isEligibleForFreeTrial, isFalse);
    expect(await bridge.purchase(item), PaywallPurchaseResult.succeeded);
    final args = calls
        .singleWhere((c) => c.method == 'googlePlayPurchase')
        .arguments as Map;
    expect(args['offerToken'], 'intro-token');
    expect(args['quoteId'], 'quote-1');
    expect(events, ['verify', 'ack']);
  });
  test('ineligible account returns only regular phases with no offer promise',
      () async {
    respond = (call) async => call.method == 'googlePlayProducts'
        ? [product(discounted: false)]
        : null;
    final item = (await bridge.products(['monthly'], '')).single;
    expect(item.subscriptionPricing!.phases, hasLength(1));
    expect(item.introductoryPriceText, isNull);
    expect(item.isEligibleForFreeTrial, isFalse);
  });
  test(
      'eligible trial keeps zero amount and renewal instead of first-month paid copy',
      () async {
    respond = (call) async =>
        call.method == 'googlePlayProducts' ? [product(trial: true)] : null;
    final item = (await bridge.products(['monthly'], '')).single;
    expect(item.isEligibleForFreeTrial, isTrue);
    expect(item.subscriptionPricing!.phases.first.priceAmount, '0.000000');
  });
  test('base plan cannot masquerade as an offer through multiple phases',
      () async {
    respond = (call) async => call.method == 'googlePlayProducts'
        ? [
            {
              ...product(),
              'offers': [
                {
                  ...offer(null),
                  'phases': [phase(7990000, count: 1, mode: 2), phase(19990000)]
                }
              ]
            }
          ]
        : null;
    await expectLater(bridge.products(['monthly'], ''), throwsFormatException);
  });
  test('ambiguous base plans fail rather than guessing a billing period',
      () async {
    respond = (call) async => call.method == 'googlePlayProducts'
        ? [
            {
              ...product(),
              'offers': [offer(null), offer('year-intro', base: 'yearly')]
            }
          ]
        : null;
    await expectLater(bridge.products(['monthly'], ''), throwsFormatException);
  });
  test(
      'same base multiple eligible offers use deterministic ID independent of server order',
      () async {
    respond = (call) async => call.method == 'googlePlayProducts'
        ? [
            {
              ...product(),
              'offers': [offer('z'), offer(null), offer('a')]
            }
          ]
        : receipt();
    final item = (await bridge.products(['monthly'], '')).single;
    await bridge.purchase(item);
    expect(
        (calls.singleWhere((c) => c.method == 'googlePlayPurchase').arguments
            as Map)['offerToken'],
        'a');
  });
  test(
      'later query does not replace quote belonging to already displayed product',
      () async {
    var sequence = 0;
    respond = (call) async => call.method == 'googlePlayProducts'
        ? [product(quote: 'q-${sequence++}')]
        : call.method == 'googlePlayPurchase'
            ? receipt()
            : null;
    final first = (await bridge.products(['monthly'], '')).single;
    await bridge.products(['monthly'], '');
    await bridge.purchase(first);
    expect(
        (calls.singleWhere((c) => c.method == 'googlePlayPurchase').arguments
            as Map)['quoteId'],
        'q-0');
  });
  test('changed native quote does not silently fall back to regular purchase',
      () async {
    respond = (call) async {
      if (call.method == 'googlePlayProducts') return [product()];
      if (call.method == 'googlePlayPurchase')
        throw PlatformException(code: 'billing_quote_changed');
      return null;
    };
    final item = (await bridge.products(['monthly'], '')).single;
    await expectLater(bridge.purchase(item), throwsA(isA<PlatformException>()));
    expect(events, isEmpty);
  });
  test('pending and cancelled do not grant or acknowledge', () async {
    var cancelled = false;
    respond = (call) async => call.method == 'googlePlayProducts'
        ? [product()]
        : call.method == 'googlePlayPurchase'
            ? cancelled
                ? {'cancelled': true}
                : receipt(pending: true)
            : null;
    final item = (await bridge.products(['monthly'], '')).single;
    expect(await bridge.purchase(item), PaywallPurchaseResult.pending);
    cancelled = true;
    expect(await bridge.purchase(item), PaywallPurchaseResult.cancelled);
    expect(events, isEmpty);
  });
  test('failed verification never acknowledges or reports success', () async {
    await bridge.dispose();
    bridge =
        PaywallGooglePlayPurchaseBridge(verifyPurchase: (_) async => false);
    final item = (await bridge.products(['monthly'], '')).single;
    expect(await bridge.purchase(item), PaywallPurchaseResult.noEntitlement);
    expect(events, isEmpty);
  });
  test('restore verifies completed purchases and skips acknowledged completion',
      () async {
    respond = (call) async => call.method == 'googlePlayRestore'
        ? [receipt(acknowledged: true), receipt(pending: true)]
        : null;
    expect(await bridge.restore(), PaywallPurchaseResult.succeeded);
    expect(events, ['verify']);
  });
  test(
      'dispose invalidates a late query and prevents all subsequent operations',
      () async {
    final pending = Completer<Object?>();
    respond = (call) async =>
        call.method == 'googlePlayProducts' ? pending.future : null;
    final loading = bridge.products(['monthly'], '');
    final check = expectLater(loading, throwsStateError);
    await bridge.dispose();
    pending.complete([product()]);
    await check;
    await expectLater(bridge.products(['monthly'], ''), throwsStateError);
    expect(calls.where((c) => c.method == 'googlePlayDispose'), hasLength(1));
  });
  test('forged product and concurrent transactions are rejected', () async {
    const forged = PaywallStoreProduct(
        productRef: 'monthly',
        storeProductId: 'monthly',
        title: '',
        displayPrice: '€1',
        disclosure: 'monthly');
    await expectLater(bridge.purchase(forged), throwsStateError);
    final item = (await bridge.products(['monthly'], '')).single;
    final pending = Completer<Object?>();
    respond = (call) async =>
        call.method == 'googlePlayPurchase' ? pending.future : null;
    final buying = bridge.purchase(item);
    await expectLater(bridge.restore(), throwsStateError);
    pending.complete({'cancelled': true});
    expect(await buying, PaywallPurchaseResult.cancelled);
  });
}
