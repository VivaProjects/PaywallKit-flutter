import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

class MemoryBundle extends CachingAssetBundle {
  MemoryBundle(this.values);
  final Map<String, List<int>> values;
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(values[key]!));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PaywallStorage storage;
  late Map<Uri, List<int>> remote;
  late WebPaywallResourceCache cache;
  late PaywallPackageArchive archive;
  setUp(() async {
    root = Directory(
        await (await Directory.systemTemp.createTemp('paywall-parity-'))
            .resolveSymbolicLinks());
    storage = PaywallStorage(directory: () async => root);
    remote = {};
    cache = WebPaywallResourceCache(
        directory: () async => Directory('${root.path}/resources'),
        download: (uri, limit, deadline) async =>
            remote[uri] ?? (throw const SocketException('offline')));
    archive = PaywallPackageArchive(
        directory: () => storage.folder('local', 'test'),
        environment: 'test',
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        allowedOrigins: {'https://example.com'},
        cache: cache);
  });
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await root.delete(recursive: true);
  });

  test(
      'attribution timeout and failed fallback do not persist; confirmed channel survives restart',
      () async {
    final attribution = PaywallQueryAttribution(
        storage: storage,
        namespace: 'app.test',
        wait: const Duration(milliseconds: 5));
    expect(await attribution.resolve(), 'organic');
    final afterTimeout =
        PaywallQueryAttribution(storage: storage, namespace: 'app.test');
    await afterTimeout.initialize();
    expect(afterTimeout.channel, isNull);
    await attribution.update(failed: true);
    final afterFailure =
        PaywallQueryAttribution(storage: storage, namespace: 'app.test');
    await afterFailure.initialize();
    expect(afterFailure.channel, isNull);
    await attribution.update(channel: 'Facebook Ads');
    final restored =
        PaywallQueryAttribution(storage: storage, namespace: 'app.test');
    expect(await restored.resolve(), 'Facebook Ads');
    final production =
        PaywallQueryAttribution(storage: storage, namespace: 'app.production');
    await production.initialize();
    expect(production.channel, isNull);
    final pending = production.resolve();
    production.dispose();
    await expectLater(pending, throwsA(PaywallFailure.cancelled));
  });

  test(
      'failed callback cannot cancel persistence of an already confirmed channel',
      () async {
    final attribution =
        PaywallQueryAttribution(storage: storage, namespace: 'race.test');
    await attribution.initialize();
    await Future.wait([
      attribution.update(channel: 'paid'),
      attribution.update(failed: true)
    ]);
    final restored =
        PaywallQueryAttribution(storage: storage, namespace: 'race.test');
    expect(await restored.resolve(), 'paid');
  });

  test(
      'local packages adopt complete revisions, reject corrupt update and survive resource clear',
      () async {
    final first = fixtures.document('fallback', revision: 1);
    final second = fixtures.document('fallback', revision: 2);
    remote.addAll(fixtures.fixture(first));
    remote.addAll(fixtures.fixture(second));
    final initial = await archive.archive(first);
    final store = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {'banner'},
        archive: archive,
        bundled: () async => initial);
    await store.adopt(first);
    await store.adopt(second);
    expect((await store.selection()).document.revision, 2);
    await store.reject(second);
    expect((await store.selection()).document.revision, 1);
    await cache.clear();
    final restored = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {'banner'},
        archive: archive,
        bundled: () async => initial);
    expect((await restored.selection()).document.revision, 1);
    expect((await restored.selection(bundledOnly: true)).source, 'bundled');
  });

  test(
      'update disable policy survives broken package and older policy cannot reopen placement',
      () async {
    final first = fixtures.document('fallback', revision: 1);
    final second = fixtures.document('fallback', revision: 2);
    remote.addAll(fixtures.fixture(first));
    final initial = await archive.archive(first);
    var clock = DateTime(2026);
    var manifest = {
      'formatVersion': 1,
      'runtimeEnvironment': 'test',
      'version': 2,
      'document': WebPaywallPackage.identity(second),
      'disabledPlacements': ['banner']
    };
    var calls = 0;
    final store = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {'banner'},
        archive: archive,
        bundled: () async => initial,
        updateUrl: Uri.parse('https://example.com/latest.json'),
        now: () => clock,
        fetch: (_) async {
          calls++;
          return jsonEncode(manifest);
        });
    expect(await store.refreshIfNeeded(), isFalse); // 包缺失，但显式开关仍需生效。
    expect(store.isDisabled('banner'), isTrue);
    expect(await store.refreshIfNeeded(), isFalse);
    expect(calls, 1);
    manifest = {
      'formatVersion': 1,
      'runtimeEnvironment': 'test',
      'version': 1,
      'document': WebPaywallPackage.identity(first),
      'disabledPlacements': []
    };
    clock = clock.add(const Duration(hours: 1));
    await store.refreshIfNeeded();
    expect(store.isDisabled('banner'), isTrue);
  });

  test('bundled assets extracted and validated without network', () async {
    final doc = fixtures.document('bundled');
    final files = fixtures.fixture(doc);
    final bundle = MemoryBundle({
      for (final entry in files.entries)
        'paywall/${entry.key.pathSegments.last}': entry.value
    });
    final local = await archive.bundled('paywall', bundle: bundle);
    expect(local.localDirectory, isNotNull);
    final lease = await cache.prepare(local, 'test');
    expect(await File(lease.pagePath).exists(), isTrue);
    lease.release();
  });

  test(
      'history keeps two successes and cannot cross request, placement or document',
      () async {
    final history = PaywallHistoryStore(archive: archive);
    for (var version = 1; version <= 3; version++) {
      final doc = fixtures.document('history', revision: version);
      remote.addAll(fixtures.fixture(doc));
      await history.record(
          requestIdentity: 'request-a',
          placement: 'banner',
          document: doc,
          configuration: '{}',
          isCurrent: () => true);
    }
    final current = fixtures.document('history', revision: 4);
    final previous = await history.previous(
        requestIdentity: 'request-a', placement: 'banner', current: current);
    expect(previous!.document.revision, 3);
    expect(
        await history.previous(
            requestIdentity: 'request-b',
            placement: 'banner',
            current: current),
        isNull);
    expect(
        await history.previous(
            requestIdentity: 'request-a', placement: 'other', current: current),
        isNull);
    expect(
        await history.previous(
            requestIdentity: 'request-a',
            placement: 'banner',
            current: fixtures.document('history', revision: 2)),
        isNull);
    final fourth = fixtures.document('history', revision: 4);
    remote.addAll(fixtures.fixture(fourth));
    await expectLater(
        history.record(
            requestIdentity: 'request-a',
            placement: 'banner',
            document: fourth,
            configuration: '{}',
            isCurrent: () => false),
        throwsA(anything));
    expect(
        (await history.previous(
                requestIdentity: 'request-a',
                placement: 'banner',
                current: fixtures.document('history', revision: 5)))!
            .document
            .revision,
        3);
  });
}
