import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';
import 'package:native_paywall/modules/web_paywall/services/web_paywall_resource_preparation.dart';
import 'paywall_parity_stores_test.dart' show MemoryBundle;
import 'web_paywall_resource_cache_test.dart' as fixtures;

class CountingValidationCache extends WebPaywallResourceCache {
  int successful = 0;
  @override
  Future<void> verifyDirectory(Directory directory, WebPaywallDocument document,
      String environment) async {
    await super.verifyDirectory(directory, document, environment);
    successful++;
  }
}

class GatedMaintenanceArchive extends PaywallPackageArchive {
  GatedMaintenanceArchive(Directory root)
      : super(
            directory: () async => root,
            environment: 'test',
            catalog: () => PaywallCatalog(
                productRefs: ['product'], recommendedRef: 'product'),
            allowedOrigins: {'https://example.com'});
  final started = Completer<void>();
  final done = Completer<void>();
  @override
  Future<void> pruneOnOpen() async {
    if (!started.isCompleted) started.complete();
    await done.future;
    throw const FileSystemException('cleanup failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory(
        await (await Directory.systemTemp.createTemp('startup-maintenance-'))
            .resolveSymbolicLinks());
  });
  tearDown(() async => root.delete(recursive: true));

  test(
      'initialization does not wait for cleanup or lose disabled policy on failure',
      () async {
    await PaywallStorage.write(File('${root.path}/state.json'), {
      'highestVersion': 2,
      'policyVersion': 2,
      'disabledPlacements': ['banner'],
      'rejected': [2]
    });
    final archive = GatedMaintenanceArchive(root);
    final store = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {'banner'},
        archive: archive,
        bundled: () async => throw StateError('unused'));
    await store.initialize().timeout(const Duration(seconds: 1));
    await archive.started.future;
    expect(store.isDisabled('banner'), isTrue);
    archive.done.complete();
    await Future<void>.delayed(Duration.zero);
    expect(store.isDisabled('banner'), isTrue);
  });

  test(
      'background cleanup retains latest pointers and live leases, removes only orphan',
      () async {
    final current = fixtures.document('current');
    final latest = fixtures.document('latest');
    final live = fixtures.document('live');
    final orphan = fixtures.document('orphan');
    final reading = fixtures.document('reading');
    Directory path(WebPaywallDocument doc) => Directory(
        '${root.path}/packages/${PaywallStorage.digest(WebPaywallPackage.identity(doc))}');
    for (final doc in [current, latest, live, orphan, reading]) {
      await path(doc).create(recursive: true);
      for (final entry in fixtures.fixture(doc).entries) {
        await File('${path(doc).path}/${entry.key.pathSegments.last}')
            .writeAsBytes(entry.value);
      }
    }
    await PaywallStorage.write(File('${root.path}/state.json'),
        {'current': WebPaywallPackage.identity(current)});
    final trash = Directory('${path(orphan).path}.trash-123');
    await trash.create(recursive: true);
    final gate = Completer<void>();
    var calls = 0;
    final archive = PaywallPackageArchive(
        directory: () async {
          if (++calls == 2) await gate.future;
          return root;
        },
        environment: 'test',
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        allowedOrigins: null);
    final store = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {},
        archive: archive,
        bundled: () async => throw StateError('unused'));
    final lease = WebPaywallResourceLease(path(live), () {});
    await store.initialize();
    await PaywallStorage.write(File('${root.path}/state.json'), {
      'current': WebPaywallPackage.identity(latest),
      'previous': WebPaywallPackage.identity(current)
    });
    // 清理尚在等待目录时有新读取，不能使用旧的候选列表删除它。
    await archive.open(WebPaywallPackage.identity(reading));
    gate.complete();
    await archive.pruneOnOpen();
    expect(await path(current).exists(), isTrue);
    expect(await path(latest).exists(), isTrue);
    expect(await path(live).exists(), isTrue);
    expect(await path(orphan).exists(), isFalse);
    expect(await trash.exists(), isFalse);
    expect(await path(reading).exists(), isTrue);
    lease.release();
  });

  test(
      'first extraction and warm bundled selection each validate once; next session revalidates',
      () async {
    final doc = fixtures.document('bundle');
    final values = {
      for (final entry in fixtures.fixture(doc).entries)
        'paywall/${entry.key.pathSegments.last}': entry.value
    };
    final bundle = MemoryBundle(values);
    final cache = CountingValidationCache();
    final archive = PaywallPackageArchive(
        directory: () async => root,
        environment: 'test',
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        allowedOrigins: {'https://example.com'},
        cache: cache);
    final store = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {},
        archive: archive,
        bundled: () => archive.bundled('paywall', bundle: bundle),
        bundledPrepared: (scope) =>
            archive.bundledForPreparation('paywall', scope, bundle: bundle));
    for (var count = 1; count <= 2; count++) {
      final scope = WebPaywallResourcePreparation();
      final result = await store.selection(preparation: scope);
      expect(cache.successful, count);
      final lease = scope.take(result.document, 'test');
      expect(lease, isNotNull);
      expect(WebPaywallResourceLease.isInUse(result.document.localDirectory!),
          isTrue);
      lease!.release();
      expect(WebPaywallResourceLease.isInUse(result.document.localDirectory!),
          isFalse);
    }
    // 磁盘和源资产同时损坏，新的展示必须拒绝，不能沿用前次凭据。
    final local = await archive.bundled('paywall', bundle: bundle);
    await File('${local.localDirectory!.path}/offline.js')
        .writeAsString('corrupt');
    values['paywall/offline.js'] = [0];
    final scope = WebPaywallResourcePreparation();
    await expectLater(store.selection(preparation: scope), throwsA(anything));
    scope.close();
    expect(WebPaywallResourceLease.isInUse(local.localDirectory!), isFalse);
    await archive.pruneOnOpen();
  });

  test('custom bundled callbacks still receive full validation', () async {
    final doc = fixtures.document('external');
    for (final entry in fixtures.fixture(doc).entries) {
      await File('${root.path}/${entry.key.pathSegments.last}')
          .writeAsBytes(entry.value);
    }
    final cache = CountingValidationCache();
    final archive = PaywallPackageArchive(
        directory: () async => root,
        environment: 'test',
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        allowedOrigins: null,
        cache: cache);
    final local = doc.withLocalDirectory(root);
    final store = PaywallLocalPackageStore(
        placement: 'settings',
        fallbackPlacements: {},
        archive: archive,
        bundled: () async => local);
    final scope = WebPaywallResourcePreparation();
    await store.selection(preparation: scope);
    expect(cache.successful, 1);
    scope.close();
    await File('${root.path}/offline.js').writeAsString('corrupt');
    await expectLater(
        store.selection(preparation: WebPaywallResourcePreparation()),
        throwsA(anything));
    await archive.pruneOnOpen();
  });
}
