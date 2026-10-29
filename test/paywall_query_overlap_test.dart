import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/paywall_client/services/paywall_query_snapshots.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

/// 仅阻塞启动索引所在目录，归因存储和联网可继续使用。
class RestoreGateStorage extends PaywallStorage {
  RestoreGateStorage(Directory root) : super(directory: () async => root);
  final entered = Completer<void>(), resume = Completer<void>();
  @override
  Future<Directory> folder(String kind, String scope) async {
    if (kind == 'query_snapshots') {
      if (!entered.isCompleted) entered.complete();
      await resume.future;
    }
    return super.folder(kind, scope);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'legacy exact-request migration can display while network response is blocked',
      () async {
    final root = Directory(
        await (await Directory.systemTemp.createTemp('legacy-overlap-'))
            .resolveSymbolicLinks());
    final resources = Directory('${root.path}/resources');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('native_paywall/resources'),
        (call) async => call.method == 'resolveCountry'
            ? (call.arguments as Map)['country']
            : resources.path);
    const env = WebPaywallEnvironment(
        os: 'iOS',
        language: 'en',
        deviceModel: 'phone',
        country: 'USA',
        appVersion: '1');
    final catalog =
        PaywallCatalog(productRefs: ['product'], recommendedRef: 'product');
    final storage = PaywallStorage(directory: () async => root);
    final entered = Completer<void>(), response = Completer<String>();
    final configuration = PaywallQueryConfiguration(
        remoteUpdatesEnabled: true,
        endpoint: Uri.parse('https://example.com/query'),
        cacheNamespace: 'legacy-overlap',
        placements: {'entry': 'settings'},
        allowedOrigins: {'https://example.com'},
        environment: () async => env,
        fetch: (_) {
          entered.complete();
          return response.future;
        });
    final request = PaywallConfigurationRequest.query(
        endpoint: configuration.endpoint,
        environment: env,
        channelKey: 'organic');
    final doc = fixtures.document('legacy');
    final files = fixtures.fixture(doc);
    final cache = WebPaywallResourceCache(
        directory: () async => resources,
        download: (uri, limit, deadline) async => files[uri]!);
    final lease = await cache.prepare(doc, 'test');
    final old = PaywallConfigurationSource(
        cacheNamespace: configuration.cacheScope,
        allowedOrigins: configuration.allowedOrigins,
        catalogs: () => {'default': catalog},
        request: () async => request,
        directory: () => storage.folder('query', configuration.cacheScope),
        fetch: (_) async => PaywallQueryResponse.configurationFor(
            'settings', doc, 'fullScreen'));
    await old.load(request, isCurrent: () => true);
    final client = PaywallClient.query(
        query: configuration, catalog: () => catalog, storage: storage);
    try {
      await client.reportAttribution(channel: 'organic');
      final resolved = client.resolve('settings');
      await entered.future.timeout(const Duration(seconds: 2));
      expect(
          (await resolved.timeout(const Duration(seconds: 2)))!
              .document
              .documentId,
          'legacy');
      expect(response.isCompleted, isFalse);
      response.complete(jsonEncode({'code': '200', 'data': []}));
      await client.waitForQueryUpdate();
      expect(client.cachedPlacement('settings')!.document.documentId, 'legacy');
    } finally {
      if (!response.isCompleted)
        response.complete(jsonEncode({'code': '200', 'data': []}));
      await client.waitForQueryUpdate();
      client.dispose();
      lease.release();
      await cache.clear();
      await WebPaywallResourceCache.shared.clear();
      messenger.setMockMethodCallHandler(
          const MethodChannel('native_paywall/resources'), null);
      await root.delete(recursive: true);
    }
  });
  test(
      'request overlaps restore; fast response cannot evict frozen launch page',
      () async {
    final root = Directory(
        await (await Directory.systemTemp.createTemp('query-overlap-'))
            .resolveSymbolicLinks());
    const env = WebPaywallEnvironment(
        os: 'iOS',
        language: 'en',
        deviceModel: 'phone',
        country: 'USA',
        appVersion: '1');
    final catalog =
        PaywallCatalog(productRefs: ['product'], recommendedRef: 'product');
    final fetched = Completer<void>();
    var requests = 0;
    final configuration = PaywallQueryConfiguration(
        remoteUpdatesEnabled: true,
        endpoint: Uri.parse('https://example.com/query'),
        cacheNamespace: 'overlap',
        placements: {'entry': 'settings'},
        allowedOrigins: {'https://example.com'},
        environment: () async => env,
        fetch: (_) async {
          requests++;
          fetched.complete();
          return jsonEncode({'code': '200', 'data': []});
        });
    final seed = PaywallQuerySnapshots(configuration, () => catalog,
        PaywallStorage(directory: () async => root));
    await seed.restore();
    final doc = fixtures.document('saved');
    final source = await Directory('${root.path}/source').create();
    for (final entry in fixtures.fixture(doc).entries) {
      await File('${source.path}/${entry.key.pathSegments.last}')
          .writeAsBytes(entry.value);
    }
    await seed.save(
        PaywallPlacement(
            name: 'settings',
            document: doc.withLocalDirectory(source),
            environment: env,
            presentation: WebPaywallPresentation.fullScreen,
            requestIdentity: 'fixture',
            configurationSnapshot: PaywallQueryResponse.configurationFor(
                'settings', doc, 'fullScreen')),
        () => true);
    final storage = RestoreGateStorage(root);
    final client = PaywallClient.query(
        query: configuration, catalog: () => catalog, storage: storage);
    try {
      await client.reportAttribution(channel: 'organic');
      var finished = false;
      final update = client.waitForQueryUpdate().then((_) {
        finished = true;
      });
      await storage.entered.future;
      await fetched.future.timeout(const Duration(seconds: 2));
      expect(finished, isFalse);
      expect(client.cachedPlacement('settings'), isNull);
      storage.resume.complete();
      await update;
      expect(client.cachedPlacement('settings')!.document.documentId, 'saved');
      // 本次仍使用恢复的旧页，明确未命中只影响下一次启动。
      final restarted = PaywallQuerySnapshots(configuration, () => catalog,
          PaywallStorage(directory: () async => root));
      expect(await restarted.restorePlacement('settings'), isNull);
      await client.waitForQueryUpdate();
      expect(requests, 1);
    } finally {
      if (!storage.resume.isCompleted) storage.resume.complete();
      client.dispose();
      await root.delete(recursive: true);
    }
  });
}
