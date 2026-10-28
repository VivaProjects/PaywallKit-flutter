import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/paywall_client/services/paywall_query_snapshots.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

/// 在真实磁盘校验前控制一个包的等待，验证其他点位无需等待它。
class GatedArchive extends PaywallPackageArchive {
  GatedArchive(PaywallPackageArchive base)
      : super(
            directory: base.directory,
            environment: base.environment,
            catalog: base.catalog,
            allowedOrigins: base.allowedOrigins);
  final slowStarted = Completer<void>();
  final release = Completer<void>();
  final calls = <String, int>{};

  @override
  Future<WebPaywallDocument> open(Map<String, dynamic> identity) async {
    final name = identity['documentId'] as String;
    calls[name] = (calls[name] ?? 0) + 1;
    if (name == 'slow') {
      if (!slowStarted.isCompleted) slowStarted.complete();
      await release.future;
    }
    return super.open(identity);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('target restores while another package is blocked; aliases verify once',
      () async {
    final root = Directory(
        await (await Directory.systemTemp.createTemp('restore-order-'))
            .resolveSymbolicLinks());
    const environment = WebPaywallEnvironment(
        os: 'iOS',
        language: 'en',
        deviceModel: 'phone',
        country: 'USA',
        appVersion: '1');
    final catalog =
        PaywallCatalog(productRefs: ['product'], recommendedRef: 'product');
    final configuration = PaywallQueryConfiguration(
        endpoint: Uri.parse('https://example.com/query'),
        cacheNamespace: 'restore-order',
        allowedOrigins: {'https://example.com'},
        placements: {'slow': 'slow', 'fast': 'fast', 'alias': 'alias'},
        environment: () async => environment);
    final storage = PaywallStorage(directory: () async => root);
    PaywallQuerySnapshots snapshots() =>
        PaywallQuerySnapshots(configuration, () => catalog, storage);
    final seed = snapshots();
    await seed.restore();
    try {
      for (final name in ['slow', 'fast', 'alias']) {
        final doc = fixtures.document(name == 'alias' ? 'fast' : name);
        final source = Directory('${root.path}/source-$name');
        await source.create();
        for (final entry in fixtures.fixture(doc).entries) {
          await File('${source.path}/${entry.key.pathSegments.last}')
              .writeAsBytes(entry.value);
        }
        await seed.save(
            PaywallPlacement(
                name: name,
                document: doc.withLocalDirectory(source),
                environment: environment.forPlacement(name),
                presentation: WebPaywallPresentation.halfSheet,
                requestIdentity: 'test',
                configurationSnapshot: PaywallQueryResponse.configurationFor(
                    name, doc, 'halfSheet')),
            () => true);
      }
      late GatedArchive gate;
      final restored = PaywallQuerySnapshots(
          configuration, () => catalog, storage,
          archiveFactory: (scope) => gate = GatedArchive(PaywallPackageArchive(
              directory: () => storage.folder('query_snapshots', scope),
              environment: 'test',
              catalog: () => catalog,
              allowedOrigins: {'https://example.com'})));
      // 只初始化索引；实际解析及摘要校验继续使用生产实现。
      await restored.restorePlacement('unknown');
      final delivered = <String>[];
      final all = restored.restore(
          preferredPlacement: () => 'slow',
          onPlacement: (value) => delivered.add(value.name));
      try {
        await gate.slowStarted.future;
        final fast = await restored
            .restorePlacement('fast')
            .timeout(const Duration(seconds: 1));
        final alias = await restored
            .restorePlacement('alias')
            .timeout(const Duration(seconds: 1));
        expect(fast!.presentation, WebPaywallPresentation.halfSheet);
        expect(alias!.document.localDirectory!.path,
            fast.document.localDirectory!.path);
        expect(gate.calls['fast'], 1);
        expect(delivered, isEmpty);
      } finally {
        gate.release.complete();
      }
      expect((await all).keys.toSet(), {'slow', 'fast', 'alias'});
      expect(gate.calls, {'slow': 1, 'fast': 1});
      // 新启动重新完整校验，不能把上一启动的校验结果用于损坏文件。
      final fast = await restored.restorePlacement('fast');
      await File('${fast!.document.localDirectory!.path}/offline.js')
          .writeAsString('corrupt');
      expect(await snapshots().restorePlacement('fast'), isNull);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
