import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/paywall_client/services/paywall_query_snapshots.dart';
import 'package:native_paywall/modules/web_paywall/services/web_paywall_resource_preparation.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'support/fake_webview.dart';
import 'paywall_flow_parity_test.dart' show FlowBridge, env, settle;
import 'web_paywall_resource_cache_test.dart' as fixtures;

/// 只统计 WebView 阶段的资源准备，校验和失败行为仍使用生产实现。
class PreparationCache extends WebPaywallResourceCache {
  int calls = 0;
  @override
  Future<WebPaywallResourceLease> prepare(
      WebPaywallDocument document, String environment,
      {Duration? timeout, List<int>? manifestBytes}) {
    calls++;
    return super.prepare(document, environment,
        timeout: timeout, manifestBytes: manifestBytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late WebPaywallDocument local;
  final catalog =
      PaywallCatalog(productRefs: ['product'], recommendedRef: 'product');
  setUp(() async {
    root = Directory(
        await (await Directory.systemTemp.createTemp('prepared-resource-'))
            .resolveSymbolicLinks());
    final doc = fixtures.document('prepared');
    for (final entry in fixtures.fixture(doc).entries) {
      await File('${root.path}/${entry.key.pathSegments.last}')
          .writeAsBytes(entry.value);
    }
    local = doc.withLocalDirectory(root);
    WebViewPlatform.instance = FakeWebViewPlatform();
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
      'fresh snapshot hands validation to WebView; next presentation verifies again',
      () async {
    final config = PaywallQueryConfiguration(
        remoteUpdatesEnabled: true,
        endpoint: Uri.parse('https://example.com/query'),
        cacheNamespace: root.path,
        placements: {'entry': 'settings'},
        allowedOrigins: {'https://example.com'},
        environment: () async => env,
        fetch: (_) async => '{"code":"200","data":[]}');
    final storage = PaywallStorage(
        directory: () async => Directory('${root.path}/storage'));
    final seed = PaywallQuerySnapshots(config, () => catalog, storage);
    await seed.restore();
    await seed.save(
        PaywallPlacement(
            name: 'settings',
            document: local,
            environment: env,
            presentation: WebPaywallPresentation.fullScreen,
            requestIdentity: 'fixture',
            configurationSnapshot: PaywallQueryResponse.configurationFor(
                'settings', local, 'fullScreen')),
        () => true);
    final client = PaywallClient.query(
        query: config, catalog: () => catalog, storage: storage);
    final cache = PreparationCache();
    PaywallFlowController flow() => PaywallFlowController(
        client: client,
        placement: 'settings',
        resourceCache: cache,
        prepare: (doc) async => PaywallSessionInput(
            document: doc, purchaseBridge: FlowBridge(), environment: env),
        openLegal: (_) {});
    final first = flow();
    PaywallFlowController? second;
    try {
      await client.reportAttribution(channel: 'organic');
      await first.load();
      await settle();
      expect(first.web.value, isNotNull);
      expect(first.web.value!.failed.value, isFalse);
      expect(cache.calls, 0);
      first.dispose();
      second = flow();
      await second.load();
      await settle();
      expect(cache.calls, 1);
      expect(second.web.value!.failed.value, isFalse);
      await client.waitForQueryUpdate();
    } finally {
      first.dispose();
      second?.dispose();
      await client.waitForQueryUpdate();
      client.dispose();
    }
  });

  test(
      'handoff is one-shot and rejects environment, identity and external corruption',
      () async {
    final scope = WebPaywallResourcePreparation();
    await scope.verify(root, local, 'test');
    expect(WebPaywallResourceLease.isInUse(root), isTrue);
    final lease = scope.take(local, 'test')!;
    expect(scope.take(local, 'test'), isNull);
    expect(WebPaywallResourceLease.isInUse(root), isTrue);
    lease.release();
    expect(WebPaywallResourceLease.isInUse(root), isFalse);
    final wrong = WebPaywallResourcePreparation();
    await wrong.verify(root, local, 'test');
    expect(wrong.take(local, 'production'), isNull);
    expect(WebPaywallResourceLease.isInUse(root), isFalse);
    final changed = WebPaywallResourcePreparation();
    await changed.verify(root, local, 'test');
    expect(
        changed.take(
            fixtures.document('prepared', revision: 2).withLocalDirectory(root),
            'test'),
        isNull);
    await File('${root.path}/offline.js').writeAsString('corrupt');
    await expectLater(WebPaywallResourceCache().prepare(local, 'test'),
        throwsFormatException);
    final rejected = WebPaywallResourcePreparation();
    await expectLater(
        rejected.verify(root, local, 'test'), throwsFormatException);
    expect(WebPaywallResourceLease.isInUse(root), isFalse);
    rejected.close();
  });

  test('cancel during publication and failed publication release all receipts',
      () async {
    final scope = WebPaywallResourcePreparation();
    final entered = Completer<void>();
    final resume = Completer<void>();
    final target = Directory('${root.path}/published');
    final pending = scope.verifyAndPublish(root, target, local, 'test',
        cache: WebPaywallResourceCache(), publish: () async {
      entered.complete();
      await resume.future;
    });
    await entered.future;
    expect(WebPaywallResourceLease.isInUse(root), isTrue);
    scope.close();
    resume.complete();
    await pending;
    expect(scope.take(local.withLocalDirectory(target), 'test'), isNull);
    expect(WebPaywallResourceLease.isInUse(root), isFalse);
    expect(WebPaywallResourceLease.isInUse(target), isFalse);
    final failed = WebPaywallResourcePreparation();
    await expectLater(
        failed.verifyAndPublish(root, target, local, 'test',
            cache: WebPaywallResourceCache(),
            publish: () async =>
                throw const FileSystemException('publish failed')),
        throwsA(isA<FileSystemException>()));
    expect(WebPaywallResourceLease.isInUse(root), isFalse);
    expect(failed.take(local.withLocalDirectory(target), 'test'), isNull);
  });

  test('cancel during verification cannot retain a late result', () async {
    final scope = WebPaywallResourcePreparation();
    final pending = scope.verify(root, local, 'test');
    scope.close();
    await pending;
    expect(scope.take(local, 'test'), isNull);
    expect(WebPaywallResourceLease.isInUse(root), isFalse);
  });
}
