import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/paywall_client/services/paywall_query_archive_batch.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

/// 计数真实归档操作，仍执行完整生产复制及摘要验证。
class CountingArchive extends PaywallPackageArchive {
  CountingArchive(
      {required super.directory, required super.catalog, required super.cache})
      : super(environment: 'test', allowedOrigins: {'https://example.com'});
  int copies = 0;
  bool failNext = false;
  @override
  Future<WebPaywallDocument> archive(WebPaywallDocument document,
      {bool Function()? isCurrent, WebPaywallResourceLease? resource}) {
    copies++;
    if (failNext) {
      failNext = false;
      return Future.error(StateError('temporary archive failure'));
    }
    return super.archive(document, isCurrent: isCurrent, resource: resource);
  }
}

void main() {
  test(
      'aliases archive once per batch; catalog, cancellation and later corruption remain checked',
      () async {
    final root = Directory(
        await (await Directory.systemTemp.createTemp('archive-batch-'))
            .resolveSymbolicLinks());
    final doc = fixtures.document('shared');
    final files = fixtures.fixture(doc);
    var catalog =
        PaywallCatalog(productRefs: ['product'], recommendedRef: 'product');
    final cache = WebPaywallResourceCache(
        directory: () async => Directory('${root.path}/resources'),
        download: (uri, limit, deadline) async => files[uri]!);
    final lease = await cache.prepare(doc, 'test');
    final archive = CountingArchive(
        directory: () async => Directory('${root.path}/archive'),
        catalog: () => catalog,
        cache: cache);
    try {
      final batch = PaywallQueryArchiveBatch();
      final values = await Future.wait(
          List.generate(3, (_) => batch.save(archive, doc, () => true, lease)));
      expect(archive.copies, 1);
      expect(values.map((v) => v.localDirectory!.path).toSet(), hasLength(1));
      final retryBatch = PaywallQueryArchiveBatch();
      archive.failNext = true;
      await expectLater(
          retryBatch.save(archive, doc, () => true, lease), throwsStateError);
      await retryBatch.save(archive, doc, () => true, lease);
      expect(archive.copies, 3);
      await expectLater(
          batch.save(archive, doc, () => false, lease), throwsStateError);
      catalog = PaywallCatalog(productRefs: ['other'], recommendedRef: 'other');
      await expectLater(
          batch.save(archive, doc, () => true, lease), throwsFormatException);
      catalog =
          PaywallCatalog(productRefs: ['product'], recommendedRef: 'product');
      await File('${values.first.localDirectory!.path}/offline.js')
          .writeAsString('bad');
      await File('${lease.directory.path}/offline.js').writeAsString('bad');
      await expectLater(
          PaywallQueryArchiveBatch().save(archive, doc, () => true, lease),
          throwsFormatException);
      expect(archive.copies, 4);
    } finally {
      lease.release();
      await cache.clear();
      await root.delete(recursive: true);
    }
  });
}
