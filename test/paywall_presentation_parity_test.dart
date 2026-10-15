import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';
import 'package:native_paywall/modules/paywall_client/controllers/paywall_sheet_controller.dart';
import 'package:native_paywall/modules/paywall_client/views/paywall_sheet_view.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'support/fake_webview.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;
import 'paywall_flow_parity_test.dart' show FlowBridge, env;

void main() {
  testWidgets(
      'sheet height freezes after debounce and unlocks only on width changes',
      (tester) async {
    final layout = PaywallSheetController();
    layout.layoutWidth(400);
    layout.report(280);
    await tester.pump(const Duration(milliseconds: 100));
    layout.report(300);
    await tester.pump(const Duration(milliseconds: 210));
    expect(layout.height.value, 300);
    layout.report(500);
    await tester.pump(const Duration(milliseconds: 210));
    expect(layout.height.value, 300);
    layout.layoutWidth(600);
    await tester.pump(const Duration(milliseconds: 210));
    expect(layout.height.value, 500);
    layout.dispose();
  });

  testWidgets(
      'ready gate mounts one surface and cancellation prevents late presentation',
      (tester) async {
    Get.testMode = true;
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    final doc = fixtures.document('page');
    final client = PaywallClient(
        configuration: PaywallConfigurationSource(
            cacheNamespace: 'ready-ui',
            allowedOrigins: {'https://example.com'},
            catalogs: () => {
                  'default': PaywallCatalog(
                      productRefs: ['product'], recommendedRef: 'product')
                },
            request: () async => PaywallConfigurationRequest(
                uri: Uri.parse('https://example.com/config'), environment: env),
            directory: () async => throw MissingPluginException(),
            fetch: (_) async => jsonEncode({
                  'version': 1,
                  'placements': {'first': 'page'},
                  'preload': [],
                  'paywalls': {'page': WebPaywallPackage.identity(doc)}
                })));
    final coordinator = PaywallPresentationController();
    final presenter = PaywallPresenter(controller: coordinator);
    final flows = <PaywallFlowController>[];
    final bridge = FlowBridge();
    PaywallFlowController create(String placement) {
      final flow = PaywallFlowController(
          client: client,
          placement: placement,
          resourceCache: WebPaywallResourceCache(
              directory: () async => throw StateError('remote')),
          openLegal: (_) {},
          prepare: (doc) async => PaywallSessionInput(
              document: doc, purchaseBridge: bridge, environment: env));
      flows.add(flow);
      return flow;
    }

    await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
            body: PaywallHost(
                controller: coordinator, child: const SizedBox.expand()))));
    final first = presenter.present(
        placement: 'first', create: create, waitsForReady: true);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(coordinator.committed, isFalse);
    platform.controller.receive({
      'type': 'ready',
      'bridgeVersion': 2,
      'capabilities': ['renderReady']
    });
    await tester.pump();
    final session = platform.controller.messages.last['sessionID'];
    platform.controller.receive({'type': 'bootstrapped', 'sessionID': session});
    platform.controller.receive({'type': 'renderReady', 'sessionID': session});
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(coordinator.committed, isTrue);
    expect(coordinator.preparation.page.value, isNull);
    flows.first.close();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(await first, PaywallSessionEventType.closed);
    final second = presenter.present(
        placement: 'first', create: create, waitsForReady: true);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    coordinator.cancelPreparation();
    await tester.pump();
    await tester.pump();
    expect(await second, isNull);
    expect(coordinator.committed, isFalse);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
    coordinator.onClose();
    Get.reset();
  });

  for (final mode in ['fullScreen', 'halfSheet', 'halfSheetLocked', 'push']) {
    testWidgets(
        '$mode route closes exactly once and next placement waits for completed transition',
        (tester) async {
      Get.testMode = true;
      final platform = FakeWebViewPlatform();
      WebViewPlatform.instance = platform;
      final doc = fixtures.document('page');
      final client = PaywallClient(
          configuration: PaywallConfigurationSource(
              cacheNamespace: 'ui',
              allowedOrigins: {'https://example.com'},
              catalogs: () => {
                    'default': PaywallCatalog(
                        productRefs: ['product'], recommendedRef: 'product')
                  },
              request: () async => PaywallConfigurationRequest(
                  uri: Uri.parse('https://example.com/config'),
                  environment: env),
              directory: () async => throw MissingPluginException(),
              fetch: (_) async => jsonEncode({
                    'version': 1,
                    'placements': {'first': 'page', 'second': 'page'},
                    'presentations': {'first': mode},
                    'preload': [],
                    'paywalls': {'page': WebPaywallPackage.identity(doc)},
                    'sessions': {
                      'first': {
                        'purchasableProductRefs': ['product'],
                        'optionalProductRefs': [],
                        'custom': {},
                        'nextPlacement': 'second'
                      }
                    }
                  })));
      final presentation = PaywallPresentationController();
      final presenter = PaywallPresenter(controller: presentation);
      final created = <PaywallFlowController>[];
      final bridge = FlowBridge();
      PaywallFlowController create(String placement) {
        final flow = PaywallFlowController(
            client: client,
            placement: placement,
            resourceCache: WebPaywallResourceCache(
                directory: () async => throw StateError('remote')),
            openLegal: (_) {},
            prepare: (doc) async => PaywallSessionInput(
                document: doc, purchaseBridge: bridge, environment: env));
        created.add(flow);
        return flow;
      }

      Future<PaywallSessionEventType?>? showing;
      await tester.pumpWidget(GetMaterialApp(
          home: Scaffold(
              body: PaywallHost(
                  controller: presentation,
                  child: Center(
                      child: ElevatedButton(
                          onPressed: () {
                            showing = presenter.present(
                                placement: 'first', create: create);
                          },
                          child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(created.length, 1);
      expect(presentation.committed, isTrue);
      if (mode == 'halfSheetLocked') {
        expect(find.byType(PaywallSheetView), findsOneWidget);
        created.first.close(); // 锁定页普通关闭无效。
        await tester.pump();
        expect(presentation.committed, isTrue);
      }
      created.first.close(force: true);
      await tester.pump(const Duration(milliseconds: 50));
      expect(created.length, 1); // 尚未退场，不能创建第二墙。
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(created.length, 2);
      expect(presentation.committed, isTrue);
      created.last.close(force: true);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(await showing, PaywallSessionEventType.closed);
      expect(presentation.active, isFalse);
      await tester.pumpWidget(const SizedBox());
      client.dispose();
      presentation.onClose();
      Get.reset();
    });
  }
}
