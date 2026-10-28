import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'support/fake_webview.dart';
import 'paywall_client_test.dart' as config;
import 'web_paywall_session_test.dart' show FakeBridge;

class GatedPlatform extends FakeWebViewPlatform {
  final configured = Completer<void>();
  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      controller = GatedWebView(params, configured.future);
}

class GatedWebView extends FakeWebViewController {
  GatedWebView(super.params, this.configured);
  final Future<void> configured;
  int loads = 0;
  bool bridgeBeforeNavigation = false;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) => configured;
  @override
  Future<void> loadFile(String path) async {
    loads++;
    bridgeBeforeNavigation = channel != null;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) => loadFile('remote');
}

class GatedCache extends WebPaywallResourceCache {
  final started = Completer<void>();
  final result = Completer<WebPaywallResourceLease>();
  @override
  Future<WebPaywallResourceLease> prepare(
      WebPaywallDocument document, String environment,
      {Duration? timeout, List<int>? manifestBytes}) {
    started.complete();
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GatedPlatform platform;
  late GatedCache cache;
  late WebPaywallController controller;
  var released = 0;
  setUp(() {
    platform = GatedPlatform();
    WebViewPlatform.instance = platform;
    cache = GatedCache();
    released = 0;
    controller = WebPaywallController(
        document:
            config.parse(config.payload()).documentForPlacement('settings')!,
        storefrontGroup: 'default',
        environment: config.environment,
        bridge: FakeBridge(),
        allowsDismiss: true,
        dismiss: () {},
        openLegal: (_) {},
        resourceCache: cache);
  });
  tearDown(() => controller.dispose());
  Future<void> tick() => Future<void>.delayed(Duration.zero);
  void resourcesReady() => cache.result.complete(WebPaywallResourceLease(
      Directory('/tmp/parallel-test'), () => released++));

  for (final resourceFirst in [true, false]) {
    test(
        'prepares concurrently and navigates only after both gates: resourceFirst=$resourceFirst',
        () async {
      controller.start();
      await cache.started.future;
      expect(platform.configured.isCompleted, isFalse);
      if (resourceFirst) {
        resourcesReady();
      } else {
        platform.configured.complete();
      }
      await tick();
      expect((platform.controller as GatedWebView).loads, 0);
      if (resourceFirst) {
        platform.configured.complete();
      } else {
        resourcesReady();
      }
      await tick();
      expect((platform.controller as GatedWebView).loads, 1);
      expect(
          (platform.controller as GatedWebView).bridgeBeforeNavigation, isTrue);
      expect(released, 0);
      controller.dispose();
      expect(released, 1);
    });

    test(
        'dispose releases late resources without navigation: resourceFirst=$resourceFirst',
        () async {
      controller.start();
      await cache.started.future;
      if (resourceFirst) {
        resourcesReady();
      } else {
        platform.configured.complete();
      }
      await tick();
      controller.dispose();
      if (resourceFirst) expect(released, 1);
      if (resourceFirst) {
        platform.configured.complete();
      } else {
        resourcesReady();
      }
      await tick();
      expect((platform.controller as GatedWebView).loads, 0);
      expect(released, 1);
    });
  }

  test('bridge failure releases a late lease and cannot navigate', () async {
    controller.start();
    await cache.started.future;
    platform.configured.completeError(StateError('channel failed'));
    await tick();
    expect(controller.failed.value, isTrue);
    resourcesReady();
    await tick();
    expect((platform.controller as GatedWebView).loads, 0);
    expect(released, 1);
  });

  test('local resource failure never falls back to remote navigation',
      () async {
    controller.dispose();
    controller = WebPaywallController(
        document: config
            .parse(config.payload())
            .documentForPlacement('settings')!
            .withLocalDirectory(Directory('/tmp/parallel-local')),
        storefrontGroup: 'default',
        environment: config.environment,
        bridge: FakeBridge(),
        allowsDismiss: true,
        dismiss: () {},
        openLegal: (_) {},
        resourceCache: cache);
    controller.start();
    await cache.started.future;
    cache.result.completeError(StateError('corrupt local package'));
    await tick();
    platform.configured.complete();
    await tick();
    expect((platform.controller as GatedWebView).loads, 0);
    expect(controller.failed.value, isTrue);
  });

  test('remote resource failure keeps existing fallback and waits for bridge',
      () async {
    controller.start();
    await cache.started.future;
    cache.result.completeError(StateError('resource failed'));
    await tick();
    expect((platform.controller as GatedWebView).loads, 0);
    platform.configured.complete();
    await tick();
    expect((platform.controller as GatedWebView).loads, 1);
    expect(
        (platform.controller as GatedWebView).bridgeBeforeNavigation, isTrue);
    expect(controller.failed.value, isFalse);
  });
}
