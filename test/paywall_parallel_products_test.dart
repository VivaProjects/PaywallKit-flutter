import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'paywall_client_test.dart' as config;
import 'support/fake_webview.dart';
import 'web_paywall_session_test.dart' show FakeBridge, settle;

/// 模拟 JavaScript 已接收空 bootstrap，但平台调用尚未返回。
class GatedBootstrapController extends FakeWebViewController {
  GatedBootstrapController(super.params);
  final started = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<Object> runJavaScriptReturningResult(String script) async {
    final result = await super.runJavaScriptReturningResult(script);
    if (messages.last['type'] == 'bootstrap') {
      started.complete();
      await resume.future;
    }
    return result;
  }
}

class GatedPlatform extends FakeWebViewPlatform {
  GatedBootstrapController get gated => controller as GatedBootstrapController;
  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      controller = GatedBootstrapController(params);
}

class ProductBridge extends FakeBridge {
  int calls = 0;
  final result = Completer<List<PaywallStoreProduct>>();
  @override
  Future<List<PaywallStoreProduct>> products(List<String> refs, String group) {
    calls++;
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GatedPlatform platform;
  late ProductBridge bridge;
  late WebPaywallController controller;
  late String session;
  setUp(() async {
    platform = GatedPlatform();
    WebViewPlatform.instance = platform;
    bridge = ProductBridge();
    controller = WebPaywallController(
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
    controller.preload();
    await settle();
    platform.controller.receive({
      'type': 'ready',
      'bridgeVersion': 2,
      'capabilities': ['productRequest', 'renderReady', 'deferredProducts']
    });
    await settle();
    session = platform.controller.messages.single['sessionID'] as String;
  });
  tearDown(() async {
    controller.dispose();
    if (!platform.gated.resume.isCompleted) platform.gated.resume.complete();
    if (!bridge.result.isCompleted) bridge.result.complete([]);
    await settle();
  });
  void request({String environment = 'test'}) => platform.controller.receive({
        'type': 'productsRequest',
        'bridgeVersion': 2,
        'sessionID': session,
        'runtimeEnvironment': environment,
        'productRefs': ['annual'],
      });

  test(
      'store query starts while bootstrap is blocked; real prices wait for ordered delivery',
      () async {
    request();
    await platform.gated.started.future;
    expect(bridge.calls, 1);
    request();
    expect(bridge.calls, 1);
    bridge.result.complete([
      const PaywallStoreProduct(
          productRef: 'annual',
          storeProductId: 'annual',
          title: 'unused',
          displayPrice: r'$10',
          disclosure: 'per year')
    ]);
    await settle();
    expect(
        platform.controller.messages.any((m) => m['type'] == 'productsUpdated'),
        isFalse);
    controller.attachPresentation();
    platform.controller.receive(
        {'type': 'purchase', 'productRef': 'annual', 'sessionID': session});
    await settle();
    expect(bridge.purchases, 0);
    platform.gated.resume.complete();
    await settle();
    final updates = platform.controller.messages
        .where((m) => m['type'] == 'productsUpdated');
    expect(updates, hasLength(1));
    expect((updates.single['products'] as List).single['displayPrice'], r'$10');
  });

  test('early store error is handled even while bootstrap remains blocked',
      () async {
    request();
    await platform.gated.started.future;
    bridge.result.completeError(StateError('store unavailable'));
    await settle();
    expect(controller.failed.value, isTrue);
    platform.gated.resume.complete();
    await settle();
    expect(
        platform.controller.messages.any((m) => m['type'] == 'productsUpdated'),
        isFalse);
  });

  test('dispose discards late prices and bridge completion', () async {
    request();
    await platform.gated.started.future;
    controller.dispose();
    bridge.result.complete([
      const PaywallStoreProduct(
          productRef: 'annual',
          storeProductId: 'annual',
          title: 'unused',
          displayPrice: r'$10',
          disclosure: 'per year')
    ]);
    platform.gated.resume.complete();
    await settle();
    expect(
        platform.controller.messages.any((m) => m['type'] == 'productsUpdated'),
        isFalse);
    expect(bridge.purchases, 0);
  });

  test('wrong environment is rejected before starting store query', () async {
    request(environment: 'production');
    await settle();
    expect(bridge.calls, 0);
    expect(controller.failed.value, isTrue);
    expect(platform.gated.started.isCompleted, isFalse);
  });

  test('product waiters wake independently on cancellation and completion',
      () async {
    request();
    await platform.gated.started.future;
    final cancelFirst = Completer<void>(), cancelSecond = Completer<void>();
    final first = controller.waitForProducts(
        cancelled: cancelFirst.future, timeout: const Duration(seconds: 2));
    final second = controller.waitForProducts(
        cancelled: cancelSecond.future, timeout: const Duration(seconds: 2));
    cancelFirst.complete();
    expect(await first, isFalse);
    bridge.result.complete([
      const PaywallStoreProduct(
          productRef: 'annual',
          storeProductId: 'annual',
          title: '',
          displayPrice: r'$10',
          disclosure: 'per year')
    ]);
    platform.gated.resume.complete();
    expect(await second, isTrue);
    expect(controller.awaitingProducts, isFalse);
    cancelSecond.complete();
  });

  test('product wait timeout and disposal release pending waits', () async {
    request();
    await platform.gated.started.future;
    final cancelled = Completer<void>();
    expect(
        await controller.waitForProducts(
            cancelled: cancelled.future, timeout: Duration.zero),
        isFalse);
    final waiting = controller.waitForProducts(
        cancelled: cancelled.future, timeout: const Duration(seconds: 2));
    controller.dispose();
    expect(await waiting, isFalse);
    cancelled.complete();
  });
}
