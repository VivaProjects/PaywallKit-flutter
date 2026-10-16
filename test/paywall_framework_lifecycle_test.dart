import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'support/fake_webview.dart';
import 'paywall_flow_parity_test.dart' show FlowBridge, env, configuration;
import 'web_paywall_resource_cache_test.dart' as fixtures;

PaywallClient makeClient() => PaywallClient(
    configuration: PaywallConfigurationSource(
        cacheNamespace: 'framework-free',
        allowedOrigins: {'https://example.com'},
        catalogs: () => {
              'default': PaywallCatalog(
                  productRefs: ['product'], recommendedRef: 'product')
            },
        request: () async => PaywallConfigurationRequest(
            uri: Uri.parse('https://example.com/config'), environment: env),
        directory: () async => throw MissingPluginException(),
        fetch: (_) async => configuration(fixtures.document('page'))));

PaywallFlowController makeFlow(PaywallClient client,
        {Future<PaywallSessionInput> Function(WebPaywallDocument)? prepare}) =>
    PaywallFlowController(
        client: client,
        placement: 'banner',
        openLegal: (_) {},
        resourceCache: WebPaywallResourceCache(
            directory: () async => throw StateError('remote')),
        prepare: prepare ??
            (doc) async => PaywallSessionInput(
                document: doc, purchaseBridge: FlowBridge(), environment: env));

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => WebViewPlatform.instance = FakeWebViewPlatform());

  testWidgets(
      'presenter uses supplied nested navigator and preserves covering route',
      (tester) async {
    final nested = GlobalKey<NavigatorState>();
    final root = GlobalKey<NavigatorState>();
    final coordinator = PaywallPresentationController();
    final client = makeClient();
    late PaywallFlowController flow;
    await tester.pumpWidget(MaterialApp(
        navigatorKey: root,
        home: Navigator(
            key: nested,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('nested home'))))));
    final presenter = PaywallPresenter(
        controller: coordinator, navigator: nested.currentState!);
    final result = presenter.present(
        placement: 'banner', create: (_) => flow = makeFlow(client));
    await frames(tester);
    expect(root.currentState!.canPop(), isFalse);
    expect(nested.currentState!.canPop(), isTrue);
    final legal = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('legal')));
    unawaited(nested.currentState!.push(legal));
    await frames(tester);
    coordinator.dispose();
    await frames(tester);
    expect(await result, isNull);
    expect(find.text('legal'), findsOneWidget);
    expect(flow.isUsable, isFalse);
    nested.currentState!.pop();
    await frames(tester);
    expect(nested.currentState!.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });

  testWidgets(
      'unmounting host cancels preparation and ignores late eligibility result',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final coordinator = PaywallPresentationController();
    final client = makeClient();
    final pending = Completer<PaywallSessionInput>();
    final hostVisible = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: ValueListenableBuilder(
            valueListenable: hostVisible,
            builder: (_, visible, __) => visible
                ? PaywallHost(
                    controller: coordinator, child: const SizedBox.expand())
                : const SizedBox())));
    final presenter = PaywallPresenter(
        controller: coordinator, navigator: navigator.currentState!);
    final result = presenter.present(
        placement: 'banner',
        waitsForReady: true,
        create: (_) => makeFlow(client, prepare: (_) => pending.future));
    await frames(tester);
    hostVisible.value = false;
    await frames(tester);
    expect(await result, isNull);
    pending.complete(PaywallSessionInput(
        document: fixtures.document('page'),
        purchaseBridge: FlowBridge(),
        environment: env));
    await frames(tester);
    expect(navigator.currentState!.canPop(), isFalse);
    expect(coordinator.active, isFalse);
    await tester.pumpWidget(const SizedBox());
    coordinator.dispose();
    hostVisible.dispose();
    client.dispose();
  });

  testWidgets(
      'failed hidden preparation releases synchronous listeners without disposal errors',
      (tester) async {
    final client = makeClient();
    final preload = PaywallPreload();
    final flow = makeFlow(client,
        prepare: (_) async => throw PaywallFailure.eligibility);
    await tester.pumpWidget(
        MaterialApp(home: PaywallPreparationView(preload: preload)));
    preload.start(flow);
    await frames(tester);
    expect(preload.page.value, isNull);
    expect(flow.isUsable, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    preload.dispose();
    client.dispose();
  });

  testWidgets(
      'raw WebView owns explicit controller lifecycle and ignores messages after unmount',
      (tester) async {
    final platform = WebViewPlatform.instance as FakeWebViewPlatform;
    final bridge = FlowBridge();
    final controller = WebPaywallController(
        document: fixtures.document('page'),
        storefrontGroup: 'default',
        environment: env,
        bridge: bridge,
        allowsDismiss: true,
        dismiss: () {},
        openLegal: (_) {},
        resourceCache: WebPaywallResourceCache(
            directory: () async => throw StateError('remote')));
    await tester.pumpWidget(MaterialApp(
        home: WebPaywallView(
            controller: controller,
            nativeFallback: (_) => const Text('fallback'))));
    await tester.pump();
    platform.controller.receive({'type': 'ready', 'bridgeVersion': 2});
    await tester.pump();
    final session = platform.controller.messages.last['sessionID'];
    platform.controller.receive({'type': 'bootstrapped', 'sessionID': session});
    await tester.pump();
    expect(controller.ready.value, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(controller.isReusable, isFalse);
    platform.controller.receive(
        {'type': 'purchase', 'sessionID': session, 'productRef': 'product'});
    await tester.pump();
    expect(bridge.purchases, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'native renderer updates products and transaction state without a host framework',
      (tester) async {
    final snapshot = PaywallSnapshot.validateTrusted(
        File('assets/onboarding.json').readAsStringSync(),
        jsonDecode(File('assets/paywall.schema.json').readAsStringSync()),
        jsonDecode(File('assets/component-catalog.json').readAsStringSync()),
        placement: 'onboarding_complete',
        locale: 'en',
        storefrontGroup: 'default',
        catalogs: {
          'default': PaywallCatalog(
              productRefs: ['annual', 'monthly'], recommendedRef: 'annual')
        },
        assetIDs: {
          'movement_hero'
        });
    final bridge = RendererBridge();
    final controller = PaywallRuntimeController(
        snapshot: snapshot,
        bridge: bridge,
        allowsDismiss: true,
        onDismiss: () {},
        openLegal: (_) {},
        track: (_) {});
    await tester.pumpWidget(MaterialApp(
        home: PaywallRendererView(
            controller: controller, assetBuilder: (_) => const SizedBox())));
    expect(controller.isLoading.value, isTrue);
    bridge.loaded.complete([
      for (final ref in ['annual', 'monthly'])
        PaywallStoreProduct(
            productRef: ref,
            storeProductId: ref,
            title: ref,
            displayPrice: r'$10',
            disclosure: 'per period')
    ]);
    await tester.pump();
    expect(controller.products.value.length, 2);
    expect(find.text(r'$10'), findsWidgets);
    final purchase = controller.purchase();
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    // 页面销毁后商店结果仍完成，但不能更新已释放的 UI 状态。
    await tester.pumpWidget(const SizedBox());
    bridge.bought.complete(PaywallPurchaseResult.succeeded);
    await purchase;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class RendererBridge implements PaywallPurchaseBridge {
  final loaded = Completer<List<PaywallStoreProduct>>();
  final bought = Completer<PaywallPurchaseResult>();
  @override
  Future<List<PaywallStoreProduct>> products(List<String> refs, String group) =>
      loaded.future;
  @override
  Future<PaywallPurchaseResult> purchase(PaywallStoreProduct product) =>
      bought.future;
  @override
  Future<PaywallPurchaseResult> restore() async =>
      PaywallPurchaseResult.noEntitlement;
}
