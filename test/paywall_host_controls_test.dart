import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'paywall_framework_lifecycle_test.dart' show makeClient, frames;
import 'paywall_flow_parity_test.dart' show FlowBridge, env;
import 'support/fake_webview.dart';

/// 完成网页握手与首屏回执，验证的动作走真实 SDK 桥接路径。
Future<void> render(WidgetTester tester, FakeWebViewController web) async {
  web.receive({
    'type': 'ready',
    'bridgeVersion': 2,
    'capabilities': ['renderReady']
  });
  await tester.pump();
  final session = web.messages.last['sessionID'];
  web.receive({'type': 'bootstrapped', 'sessionID': session});
  web.receive({'type': 'renderReady', 'sessionID': session});
  await tester.pump();
}

/// 用独立会话验证宿主展示控制，不依赖全局导航或状态框架。
PaywallFlowController flowFor(PaywallClient client, FlowBridge bridge) =>
    PaywallFlowController(
        client: client,
        placement: 'banner',
        presentationOverride: WebPaywallPresentation.push,
        openLegal: (_) {},
        resourceCache: WebPaywallResourceCache(
            directory: () async => throw StateError('remote')),
        prepare: (doc) async => PaywallSessionInput(
            document: doc, purchaseBridge: bridge, environment: env));

void main() {
  setUp(() => WebViewPlatform.instance = FakeWebViewPlatform());

  testWidgets('locked sheet rejects system close but accepts visible H5 close',
      (tester) async {
    final client = makeClient();
    final flow = PaywallFlowController(
        client: client,
        placement: 'banner',
        presentationOverride: WebPaywallPresentation.halfSheetLocked,
        openLegal: (_) {},
        resourceCache: WebPaywallResourceCache(
            directory: () async => throw StateError('remote')),
        prepare: (doc) async => PaywallSessionInput(
            document: doc, purchaseBridge: FlowBridge(), environment: env));
    PaywallSessionEventType? exit;
    flow.onExit = (result) => exit = result;
    await tester
        .pumpWidget(MaterialApp(home: PaywallFlowView(controller: flow)));
    await frames(tester);
    final web = (WebViewPlatform.instance as FakeWebViewPlatform).controller;
    await render(tester, web);
    flow.close();
    expect(exit, isNull);
    flow.detach();
    flow.closeFromWeb();
    expect(exit, isNull);
    flow.attach();
    web.receive({'type': 'close'});
    await tester.pump();
    expect(exit, PaywallSessionEventType.closed);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });

  testWidgets('native back and push override survive an observer error',
      (tester) async {
    final client = makeClient();
    final flow = flowFor(client, FlowBridge());
    final coordinator = PaywallPresentationController();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator, home: const Scaffold(body: Text('home'))));
    var presented = 0;
    final result = PaywallPresenter(
            controller: coordinator, navigator: navigator.currentState!)
        .present(
            placement: 'banner',
            create: (_) => flow,
            showBackButton: true,
            onPresented: () {
              presented++;
              throw StateError('host observer');
            });
    await frames(tester);
    expect(presented, 1);
    expect(flow.presentation, WebPaywallPresentation.push);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await frames(tester);
    expect(await result, PaywallSessionEventType.closed);
    expect(navigator.currentState!.canPop(), isFalse);
    expect(flow.isUsable, isFalse);
    await tester.pumpWidget(const SizedBox());
    coordinator.dispose();
    client.dispose();
  });

  testWidgets('hidden preparation and reattachment preserve result callbacks',
      (tester) async {
    final client = makeClient();
    final bridge = FlowBridge();
    final flow = flowFor(client, bridge);
    String? legal;
    flow.openLegal = (value) => legal = value;
    final visible = ValueNotifier(false);
    PaywallSessionEventType? exit;
    flow.onExit = (result) => exit = result;
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder(
            valueListenable: visible,
            builder: (_, value, __) =>
                PaywallFlowView(controller: flow, isPresented: value))));
    await frames(tester);
    final platform = WebViewPlatform.instance as FakeWebViewPlatform;
    await render(tester, platform.controller);
    expect(flow.ready.value, isTrue);
    platform.controller.receive({'type': 'purchase', 'productRef': 'product'});
    await tester.pump();
    expect(bridge.purchases, 0);
    visible.value = true;
    await tester.pump();
    visible.value = false;
    await tester.pump();
    platform.controller.receive({'type': 'purchase', 'productRef': 'product'});
    await tester.pump();
    expect(bridge.purchases, 0);
    // 隐藏状态重建网页，仍不得继承已展示状态或丢失回调。
    visible.value = true;
    await tester.pump();
    platform.controller.receive({'type': 'terms'});
    await tester.pump();
    expect(legal, 'terms');
    visible.value = false;
    await tester.pump();
    await flow.retry();
    await tester.pump();
    await render(tester, platform.controller);
    platform.controller.receive({'type': 'purchase', 'productRef': 'product'});
    await tester.pump();
    expect(bridge.purchases, 0);
    visible.value = true;
    await tester.pump();
    platform.controller.receive({'type': 'purchase', 'productRef': 'product'});
    await tester.pump();
    expect(bridge.purchases, 1);
    expect(exit, PaywallSessionEventType.purchaseFinished);
    await tester.pumpWidget(const SizedBox());
    visible.dispose();
    client.dispose();
  });
}
