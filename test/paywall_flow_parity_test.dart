import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'support/fake_webview.dart';
import 'paywall_parity_stores_test.dart' show MemoryBundle;
import 'web_paywall_resource_cache_test.dart' as fixtures;

class FlowBridge implements PaywallPurchaseBridge {
  int purchases = 0;
  @override
  Future<List<PaywallStoreProduct>> products(
          List<String> references, String group) async =>
      [
        for (final ref in references)
          PaywallStoreProduct(
              productRef: ref,
              storeProductId: ref,
              title: '',
              displayPrice: r'$10',
              disclosure: 'per year')
      ];
  @override
  Future<PaywallPurchaseResult> purchase(PaywallStoreProduct product) async {
    purchases++;
    return PaywallPurchaseResult.succeeded;
  }

  @override
  Future<PaywallPurchaseResult> restore() async =>
      PaywallPurchaseResult.succeeded;
}

/// 只延迟成功记录，流程、WebView、回退和缓存仍使用生产实现。
class RecordingClient extends PaywallClient {
  RecordingClient({required super.configuration})
      : super(retainedPlacements: {'banner'});
  final records = <({
    PaywallPlacement page,
    bool Function() current,
    Completer<void> done
  })>[];
  @override
  Future<void> recordSuccess(
      PaywallPlacement selected, bool Function() isCurrent) {
    final done = Completer<void>();
    records.add((page: selected, current: isCurrent, done: done));
    return done.future;
  }
}

const env = WebPaywallEnvironment(
    os: 'iOS',
    language: 'en',
    deviceModel: 'phone',
    country: 'USA',
    appVersion: '1');
String configuration(WebPaywallDocument doc) => jsonEncode({
      'version': 1,
      'placements': {'banner': doc.documentId},
      'paywalls': {doc.documentId: WebPaywallPackage.identity(doc)},
      'preload': []
    });
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));
Future<void> bootstrap(FakeWebViewPlatform platform) async {
  await settle();
  platform.controller.receive({
    'type': 'ready',
    'bridgeVersion': 2,
    'capabilities': ['renderReady']
  });
  await settle();
}

Future<void> ready(FakeWebViewPlatform platform) async {
  final session = platform.controller.messages.last['sessionID'];
  platform.controller.receive({'type': 'bootstrapped', 'sessionID': session});
  platform.controller.receive({'type': 'renderReady', 'sessionID': session});
  await settle();
}

Future<void> fail(FakeWebViewPlatform platform) async {
  final session = platform.controller.messages.last['sessionID'];
  platform.controller.receive({'type': 'renderFailed', 'sessionID': session});
  await settle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeWebViewPlatform platform;
  late Map<Uri, List<int>> remote;
  late WebPaywallResourceCache cache;
  late PaywallClient client;
  late FlowBridge bridge;
  late WebPaywallDocument current;
  late PaywallStorage storage;
  late List<PaywallFlowController> flows;
  setUp(() async {
    root = Directory(
        await (await Directory.systemTemp.createTemp('paywall-flow-'))
            .resolveSymbolicLinks());
    storage = PaywallStorage(directory: () async => root);
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    remote = {};
    bridge = FlowBridge();
    flows = [];
    current = fixtures.document('page');
    remote.addAll(fixtures.fixture(current));
    cache = WebPaywallResourceCache(
        directory: () async => Directory('${root.path}/resources'),
        download: (uri, limit, deadline) async => remote[uri]!);
    client = PaywallClient(
        retainedPlacements: {'banner'},
        configuration: PaywallConfigurationSource(
            cacheNamespace: 'app',
            allowedOrigins: {'https://example.com'},
            catalogs: () => {
                  'default': PaywallCatalog(
                      productRefs: ['product'], recommendedRef: 'product')
                },
            request: () async => PaywallConfigurationRequest(
                uri: Uri.parse('https://example.com/config'), environment: env),
            directory: () async => root,
            fetch: (_) async => configuration(current)));
  });
  tearDown(() async {
    for (final flow in flows) {
      flow.cancel();
    }
    client.dispose();
    await settle();
    await root.delete(recursive: true);
  });
  PaywallFlowController create(
      {Object identity = 0, Duration timeout = const Duration(seconds: 12)}) {
    final flow = PaywallFlowController(
        client: client,
        placement: 'banner',
        resourceCache: cache,
        cacheIdentity: identity,
        timeout: timeout,
        openLegal: (_) {},
        prepare: (doc) async => PaywallSessionInput(
            document: doc, purchaseBridge: bridge, environment: env));
    flows.add(flow);
    return flow;
  }

  test(
      'preload blocks actions and consumes only once for matching owner and identity',
      () async {
    final flow = create();
    final preload = PaywallPreload();
    preload.start(flow, cacheIdentity: 'price-v1');
    // 等待异步资源准备完成，避免固定 30ms 在并行测试下抢先访问 WebView。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (flow.web.value == null && DateTime.now().isBefore(deadline)) {
      await settle();
    }
    expect(flow.web.value, isNotNull);
    await bootstrap(platform);
    await ready(platform);
    expect(preload.isReady, isTrue);
    platform.controller.receive({'type': 'purchase', 'productRef': 'product'});
    await settle();
    expect(bridge.purchases, 0);
    expect(preload.consume(client, 'banner', cacheIdentity: 'wrong'), isNull);
    expect(preload.consume(client, 'banner', cacheIdentity: 'price-v1'),
        same(flow));
    expect(
        preload.consume(client, 'banner', cacheIdentity: 'price-v1'), isNull);
    flow.attach();
    platform.controller.receive({'type': 'purchase', 'productRef': 'product'});
    await settle();
    expect(bridge.purchases, 1);
  });

  test(
      'close retains compatible rendered page but price identity change forces new WebView',
      () async {
    final first = create(identity: 'same');
    await first.load();
    first.attach();
    await bootstrap(platform);
    await ready(platform);
    final original = first.web.value;
    first.close();
    first.cancel();
    final second = create(identity: 'same');
    await second.load();
    second.attach();
    expect(second.web.value, same(original));
    expect(second.ready.value, isTrue);
    second.close();
    second.cancel();
    final third = create(identity: 'different');
    await third.load();
    expect(third.web.value, isNot(same(original)));
    expect(third.ready.value, isFalse);
  });

  test(
      'current failure advances once through history, update and bundled without rebinding products',
      () async {
    final archive = PaywallPackageArchive(
        directory: () => storage.folder('archive', 'app'),
        environment: 'test',
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        allowedOrigins: {'https://example.com'},
        cache: cache);
    final bundled = fixtures.document('fallback', revision: 1);
    final update = fixtures.document('fallback', revision: 2);
    remote.addAll(fixtures.fixture(bundled));
    remote.addAll(fixtures.fixture(update));
    final bundledFiles = fixtures.fixture(bundled);
    final local = await archive.bundled('fallback',
        bundle: MemoryBundle({
          for (final entry in bundledFiles.entries)
            'fallback/${entry.key.pathSegments.last}': entry.value,
        }));
    final store = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {'banner'},
        archive: archive,
        bundled: () async => local);
    await store.adopt(update);
    final history = PaywallHistoryStore(archive: archive);
    client.useLocalPackages(store,
        history: history, previousVersionPlacements: {'banner'});
    final previous = (await client.resolve('banner'))!;
    await client.recordSuccess(previous, () => true);
    current = fixtures.document('page', revision: 2);
    remote.addAll(fixtures.fixture(current));
    client.invalidate();
    final flow = create();
    await flow.load();
    flow.attach();
    await bootstrap(platform);
    await fail(platform);
    expect(flow.selected!.source, 'previous_version');
    expect(flow.selected!.document.revision, 1);
    await bootstrap(platform);
    await fail(platform);
    expect(flow.selected!.source, 'update');
    expect(flow.selected!.document.documentId, 'fallback');
    await bootstrap(platform);
    await fail(platform);
    expect(flow.selected!.source, 'bundled');
    expect(flow.selected!.document.revision, 1);
    await bootstrap(platform);
    await ready(platform);
    expect(flow.ready.value, isTrue);
    expect(flow.selected!.name, 'banner');
    expect((await store.selection()).source, 'bundled');
  });

  test(
      'cached preload parks a ready surface and rebinds it for a later presentation',
      () async {
    final warmer = PaywallCachedPreload();
    final initial = create();
    warmer.start(initial);
    await bootstrap(platform);
    final web = initial.web.value;
    await ready(platform);
    await settle();
    expect(warmer.preload.page.value, isNull);
    final next = create();
    await next.load();
    next.attach();
    expect(next.web.value, same(web));
    expect(next.ready.value, isTrue);
    warmer.cancel();
  });

  test('cancelled prepare cannot attach a late WebView', () async {
    final pending = Completer<PaywallSessionInput>();
    final flow = PaywallFlowController(
        client: client,
        placement: 'banner',
        resourceCache: cache,
        openLegal: (_) {},
        prepare: (_) => pending.future);
    flows.add(flow);
    final task = flow.load();
    await settle();
    flow.cancel();
    pending.complete(PaywallSessionInput(
        document: current, purchaseBridge: bridge, environment: env));
    await task;
    expect(flow.web.value, isNull);
  });

  test(
      'success record belongs to each actual page; stale parking cannot retain fallback',
      () async {
    final recording = RecordingClient(configuration: client.configuration);
    client.dispose();
    client = recording;
    final bundled = fixtures.document('fallback');
    final archive = PaywallPackageArchive(
        directory: () => storage.folder('archive', 'recording'),
        environment: 'test',
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        allowedOrigins: {'https://example.com'},
        cache: cache);
    final local = await archive.bundled('fallback',
        bundle: MemoryBundle({
          for (final entry in fixtures.fixture(bundled).entries)
            'fallback/${entry.key.pathSegments.last}': entry.value,
        }));
    client.useLocalPackages(PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {'banner'},
        archive: archive,
        bundled: () async => local));
    final flow = create();
    try {
      await flow.load();
      await bootstrap(platform);
      await ready(platform);
      expect(recording.records, hasLength(1));
      final firstWeb = flow.web.value;
      final stalePark = flow.parkInCache(() => true);
      expect(recording.records, hasLength(1));
      await fail(platform);
      await bootstrap(platform);
      await ready(platform);
      expect(flow.selected!.source, 'bundled');
      expect(flow.web.value, isNot(same(firstWeb)));
      expect(recording.records, hasLength(2));
      expect(recording.records.first.current(), isFalse);
      expect(recording.records.last.current(), isTrue);
      recording.records.first.done.complete();
      expect(await stalePark, isFalse);
      final currentWeb = flow.web.value;
      final freshPark = flow.parkInCache(() => true);
      expect(recording.records, hasLength(2));
      recording.records.last.done.complete();
      expect(await freshPark, isTrue);
      // 保留成功后当前流程退出，网页仍由 Client 缓存持有。
      expect(flow.web.value, isNull);
      expect(currentWeb!.isReusable, isTrue);
    } finally {
      for (final record in recording.records) {
        if (!record.done.isCompleted) record.done.complete();
      }
    }
  });
}
