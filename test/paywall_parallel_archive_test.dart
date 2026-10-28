import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/paywall_client/services/paywall_archive_queue.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

/// 只阻塞复制后的目标验证，源包与目标包都继续使用真实完整校验。
class GatedArchiveCache extends WebPaywallResourceCache {
  final entered = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<void> verifyDirectory(Directory directory, WebPaywallDocument document,
      String environment) async {
    if (directory.path.split('/').last.startsWith('write-') &&
        document.documentId == 'slow') {
      if (!entered.isCompleted) entered.complete();
      await resume.future;
    }
    await super.verifyDirectory(directory, document, environment);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('slow target verification does not block a different complete archive',
      () async {
    final root = Directory(
        await (await Directory.systemTemp.createTemp('parallel-archive-'))
            .resolveSymbolicLinks());
    final cache = GatedArchiveCache();
    final archive = PaywallPackageArchive(
        directory: () async => Directory('${root.path}/archive'),
        environment: 'test',
        allowedOrigins: {'https://example.com'},
        cache: cache,
        catalog: () => PaywallCatalog(
            productRefs: ['product'], recommendedRef: 'product'));
    Future<WebPaywallDocument> source(String name) async {
      final doc = fixtures.document(name);
      final dir = await Directory('${root.path}/$name').create();
      for (final entry in fixtures.fixture(doc).entries) {
        await File('${dir.path}/${entry.key.pathSegments.last}')
            .writeAsBytes(entry.value);
      }
      return doc.withLocalDirectory(dir);
    }

    final slow = await source('slow');
    final fast = await source('fast');
    final first = archive.archive(slow);
    try {
      await cache.entered.future.timeout(const Duration(seconds: 2));
      final completed =
          await archive.archive(fast).timeout(const Duration(seconds: 2));
      expect(
          await File('${completed.localDirectory!.path}/offline.html').exists(),
          isTrue);
      await cache.verifyDirectory(completed.localDirectory!, completed, 'test');
      // 失效请求不能发布新包；另一个包仍被阻塞也不影响它独立失败。
      final stale = await source('stale');
      await expectLater(
          archive.archive(stale, isCurrent: () => false), throwsStateError);
      // 复制的目标仍必须通过摘要检查，不能因为并行而接受损坏资源。
      final corrupt = await source('corrupt');
      await File('${corrupt.localDirectory!.path}/offline.js')
          .writeAsString('bad');
      await expectLater(archive.archive(corrupt), throwsA(anything));
    } finally {
      cache.resume.complete();
      await first;
      await root.delete(recursive: true);
    }
  });

  test(
      'same-key waiters do not consume slots; only two distinct operations run',
      () async {
    final queue = PaywallArchiveQueue();
    final a = Completer<void>(), b = Completer<void>();
    final started = <String>[];
    var active = 0, maximum = 0;
    Future<void> work(String name, Future<void> wait) async {
      started.add(name);
      active++;
      if (active > maximum) maximum = active;
      await wait;
      active--;
    }

    final first = queue.run('a', () => work('a1', a.future));
    final second = queue.run('a', () => work('a2', Future.value()));
    final third = queue.run('b', () => work('b', b.future));
    final fourth = queue.run('c', () => work('c', Future.value()));
    try {
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a1', 'b']);
      a.complete();
      await first;
      await second;
      await fourth;
      expect(started.indexOf('a2'), greaterThan(started.indexOf('a1')));
      expect(maximum, 2);
    } finally {
      if (!a.isCompleted) a.complete();
      b.complete();
      await Future.wait([first, second, third, fourth]);
    }
  });

  test('failure frees both same-key tail and shared slot', () async {
    final queue = PaywallArchiveQueue();
    final failed = queue.run<int>('a', () async => throw StateError('failed'));
    final next = queue.run<int>('a', () async => 42);
    final other = queue.run<int>('b', () async => 7);
    await expectLater(failed, throwsStateError);
    expect(await next, 42);
    expect(await other, 7);
  });
}
