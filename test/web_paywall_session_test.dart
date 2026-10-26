import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'paywall_client_test.dart' as config;
import 'support/fake_webview.dart';

class FakeBridge implements PaywallPurchaseBridge {
  int purchases = 0;
  Completer<PaywallPurchaseResult>? pending;
  List<String> available = ['annual', 'compare'];
  @override
  Future<List<PaywallStoreProduct>> products(
          List<String> references, String storefrontGroup) async =>
      [
        for (final ref in available)
          PaywallStoreProduct(
              productRef: ref,
              storeProductId: ref,
              title: 'Native title must not leak',
              displayPrice: r'$10',
              disclosure: 'per year')
      ];
  @override
  Future<PaywallPurchaseResult> purchase(PaywallStoreProduct product) async {
    purchases++;
    return pending?.future ?? PaywallPurchaseResult.succeeded;
  }

  @override
  Future<PaywallPurchaseResult> restore() async =>
      pending?.future ?? PaywallPurchaseResult.noEntitlement;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeWebViewPlatform platform;
  late FakeBridge bridge;
  late WebPaywallController controller;
  setUp(() {
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    bridge = FakeBridge();
    final configuration = config.parse(config.payload());
    controller = WebPaywallController(
        document: configuration.documentForPlacement('settings')!,
        storefrontGroup: 'default',
        environment: config.environment.forPlacement('settings'),
        bridge: bridge,
        sessionPolicy: configuration.sessions['settings'],
        allowsDismiss: true,
        dismiss: () {},
        openLegal: (_) {},
        resourceCache: WebPaywallResourceCache(
            directory: () async => throw StateError('remote only')));
    controller.start();
  });
  tearDown(() {
    controller.dispose();
  });

  for (final action in ['purchase', 'restore']) {
    test('$action blocks close until the host transaction completes', () async {
      bridge.pending = Completer<PaywallPurchaseResult>();
      var dismissals = 0;
      controller.dismiss = () => dismissals++;
      await settle();
      platform.controller.receive({'type': 'ready', 'bridgeVersion': 2});
      await settle();
      platform.controller.receive({'type': 'bootstrapped'});
      await settle();
      platform.controller.receive({'type': action, 'productRef': 'annual'});
      await settle();
      controller.close();
      expect(controller.isProcessing, isTrue);
      expect(dismissals, 0);
      bridge.pending!.complete(PaywallPurchaseResult.noEntitlement);
      await settle();
      expect(controller.isProcessing, isFalse);
      expect(platform.controller.messages.last['type'], '${action}Result');
      controller.close();
      expect(dismissals, 1);
    });
  }

  test('policy prevents comparison purchase and bootstrap excludes native copy',
      () async {
    await settle();
    platform.controller.receive({'type': 'ready', 'bridgeVersion': 2});
    await settle();
    final bootstrap = platform.controller.messages
        .singleWhere((m) => m['type'] == 'bootstrap');
    expect(
        (bootstrap['products'] as List)
            .every((product) => !(product as Map).containsKey('title')),
        isTrue);
    expect(bootstrap['custom']['placement'], 'settings');
    platform.controller.receive({'type': 'bootstrapped'});
    await settle();
    expect(controller.ready.value, isTrue);
    platform.controller.receive({'type': 'purchase', 'productRef': 'compare'});
    await settle();
    expect(bridge.purchases, 0);
    platform.controller.receive({'type': 'purchase', 'productRef': 'annual'});
    await settle();
    expect(bridge.purchases, 1);
    controller.close();
    platform.controller.receive({'type': 'purchase', 'productRef': 'annual'});
    await settle();
    expect(bridge.purchases, 1);
  });

  test('missing required product fails while optional product may be absent',
      () async {
    bridge.available = ['compare'];
    await settle();
    platform.controller.receive({'type': 'ready', 'bridgeVersion': 2});
    await settle();
    expect(controller.failed.value, isTrue);
    expect(platform.controller.messages, isEmpty);
  });

  test('missing optional product still bootstraps required product', () async {
    bridge.available = ['annual'];
    await settle();
    platform.controller.receive({'type': 'ready', 'bridgeVersion': 2});
    await settle();
    expect(controller.failed.value, isFalse);
    expect(
        platform.controller.messages
            .singleWhere((m) => m['type'] == 'bootstrap')['products'],
        hasLength(1));
  });
}
