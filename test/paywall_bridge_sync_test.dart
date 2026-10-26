import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'paywall_client_test.dart' as config;
import 'support/fake_webview.dart';
import 'web_paywall_session_test.dart' show FakeBridge, settle;

class ControlledBridge extends FakeBridge implements PaywallStoreActionPolicy {
  final productsResult = Completer<List<PaywallStoreProduct>>();
  @override
  bool requiresStoreProducts = true;
  @override
  bool allowsStoreActions = true;
  @override
  Future<List<PaywallStoreProduct>> products(List<String> refs, String group) =>
      productsResult.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('logging override is independent from runtime environment', () {
    addTearDown(() => PaywallLogging.mode = PaywallLoggingMode.automatic);
    PaywallLogging.mode = PaywallLoggingMode.automatic;
    expect(PaywallLogging.isEnabled('test'), isTrue);
    expect(PaywallLogging.isEnabled('production'), isFalse);
    PaywallLogging.mode = PaywallLoggingMode.enabled;
    expect(PaywallLogging.isEnabled('production'), isTrue);
    PaywallLogging.mode = PaywallLoggingMode.disabled;
    expect(PaywallLogging.isEnabled('test'), isFalse);
  });
  for (final deferred in [false, true]) {
    test(
        'deferred=$deferred preserves requested IDs and presentation lifecycle',
        () async {
      final platform = FakeWebViewPlatform();
      WebViewPlatform.instance = platform;
      final bridge = ControlledBridge();
      final controller = WebPaywallController(
          document:
              config.parse(config.payload()).documentForPlacement('settings')!,
          storefrontGroup: 'settings',
          environment: config.environment,
          bridge: bridge,
          allowsDismiss: true,
          dismiss: () {},
          openLegal: (_) {},
          resourceCache: WebPaywallResourceCache(
              directory: () async => throw StateError('remote')));
      addTearDown(controller.dispose);
      controller.preload();
      await settle();
      platform.controller.receive({
        'type': 'ready',
        'bridgeVersion': 2,
        'capabilities': [
          'productRequest',
          'renderReady',
          if (deferred) 'deferredProducts'
        ]
      });
      await settle();
      final session = platform.controller.messages.single['sessionID'];
      platform.controller.receive({
        'type': 'productsRequest',
        'bridgeVersion': 2,
        'sessionID': session,
        'runtimeEnvironment': 'test',
        'productRefs': ['compare', 'annual']
      });
      await settle();
      expect(controller.requestedProductRefs, ['compare', 'annual']);
      if (deferred) {
        expect(
            platform.controller.messages
                .lastWhere((m) => m['type'] == 'bootstrap')['type'],
            'bootstrap');
        expect(
            platform.controller.messages
                .lastWhere((m) => m['type'] == 'bootstrap')['products'],
            isEmpty);
        platform.controller
            .receive({'type': 'bootstrapped', 'sessionID': session});
        platform.controller
            .receive({'type': 'renderReady', 'sessionID': session});
        await settle();
        expect(controller.ready.value, isTrue);
        expect(
            platform.controller.messages
                .any((m) => m['type'] == 'presentationState'),
            isTrue);
        expect(platform.controller.messages.last['visible'], isFalse);
        controller.attachPresentation();
        await settle();
        expect(platform.controller.messages.last['visible'], isTrue);
        platform.controller
            .receive({'type': 'purchase', 'productRef': 'annual'});
        await settle();
        expect(platform.controller.messages.last['result'], 'failed');
      } else {
        expect(platform.controller.messages, hasLength(1));
      }
      bridge.productsResult.complete([
        PaywallStoreProduct(
            productRef: 'annual',
            storeProductId: 'annual',
            title: 'ignored',
            displayPrice: r'$10',
            disclosure: 'per year')
      ]);
      await settle();
      final productMessage = platform.controller.messages.lastWhere(
          (m) => m['type'] == (deferred ? 'productsUpdated' : 'bootstrap'));
      expect(productMessage['products'], hasLength(1));
      if (!deferred) {
        platform.controller
            .receive({'type': 'bootstrapped', 'sessionID': session});
        platform.controller
            .receive({'type': 'renderReady', 'sessionID': session});
        await settle();
        controller.attachPresentation();
      }
      controller.pausePresentation();
      await settle();
      expect(platform.controller.messages.last['visible'], isFalse);
      controller.attachPresentation();
      await settle();
      expect(platform.controller.messages.last['visible'], isTrue);
      expect(controller.requestedProductRefs, ['compare', 'annual']);
    });
  }
  test(
      'display-only bridge allows empty products and rejects store actions explicitly',
      () async {
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    final bridge = ControlledBridge()
      ..requiresStoreProducts = false
      ..allowsStoreActions = false;
    final controller = WebPaywallController(
        document:
            config.parse(config.payload()).documentForPlacement('settings')!,
        storefrontGroup: 'settings',
        environment: config.environment,
        bridge: bridge,
        allowsDismiss: true,
        dismiss: () {},
        openLegal: (_) {},
        resourceCache: WebPaywallResourceCache(
            directory: () async => throw StateError('remote')));
    addTearDown(controller.dispose);
    controller.start();
    await settle();
    platform.controller.receive({'type': 'ready', 'bridgeVersion': 2});
    bridge.productsResult.complete([]);
    await settle();
    expect(
        platform.controller.messages
            .singleWhere((m) => m['type'] == 'bootstrap')['products'],
        isEmpty);
    platform.controller.receive({'type': 'bootstrapped'});
    await settle();
    expect(controller.ready.value, isTrue);
    expect(controller.requestedProductRefs, isEmpty);
    platform.controller.receive({'type': 'restore'});
    await settle();
    expect(platform.controller.messages.last,
        {'type': 'restoreResult', 'result': 'failed'});
    expect(controller.failed.value, isFalse);
  });
}
