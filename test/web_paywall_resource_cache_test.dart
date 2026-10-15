import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/modules/paywall_renderer/models/paywall_catalog.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_document.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';
import 'package:native_paywall/modules/web_paywall/services/web_paywall_resource_cache.dart';

/// 使用真实清单解析和磁盘校验，仅替换网络传输。
WebPaywallDocument document(String name, {int revision = 1}) =>
    WebPaywallDocument.parse({
      'kind': 'web-paywall',
      'bridgeVersion': 2,
      'documentId': name,
      'revision': revision,
      'pageUrl': 'https://example.com/$name/v$revision/index.html',
      'catalogKey': 'default',
      'productRefs': ['product'],
      'initialProductRef': 'product',
    },
        allowedOrigins: {
          'https://example.com'
        },
        catalog: PaywallCatalog(
            productRefs: ['product'], recommendedRef: 'product'));

/// 模拟发布产物，所有文件与服务端摘要一致。
Map<Uri, List<int>> fixture(WebPaywallDocument doc) {
  final base = doc.pageUri.resolve('.');
  final files = <String, List<int>>{
    'offline.html': utf8.encode('<html>offline</html>'),
    'offline.js': utf8.encode('window.loaded=true;'),
    'content.json': utf8.encode('{}'),
    'page.json': utf8.encode('{}'),
  };
  return {
    for (final e in files.entries) base.resolve(e.key): e.value,
    base.resolve('package.json'): utf8.encode(jsonEncode({
      'formatVersion': 1,
      'runtimeEnvironment': 'test',
      'document': WebPaywallPackage.identity(doc),
      'entry': 'offline.html',
      'files': [
        for (final e in files.entries)
          {
            'path': e.key,
            'size': e.value.length,
            'sha256': sha256.convert(e.value).toString()
          }
      ],
    })),
  };
}

void main() {
  late Directory root;
  late Map<Uri, List<int>> remote;
  late List<Uri> requests;
  setUp(() async {
    root = Directory(
        await (await Directory.systemTemp.createTemp('paywall-test-'))
            .resolveSymbolicLinks());
    remote = {};
    requests = [];
  });
  tearDown(() async {
    // 等待租约释放触发的异步清理，避免测试自身删除正在扫描的目录。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (await root.exists()) await root.delete(recursive: true);
  });
  Future<List<int>> fetch(Uri uri, int limit, DateTime deadline) async {
    requests.add(uri);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (!remote.containsKey(uri)) throw const HttpException('404');
    return remote[uri]!;
  }

  WebPaywallResourceCache cache({int capacity = 300 * 1024 * 1024}) =>
      WebPaywallResourceCache(
          directory: () async => root,
          download: fetch,
          capacityBytes: capacity);

  test('coalesces requests and survives a new cache instance without network',
      () async {
    final doc = document('a');
    remote.addAll(fixture(doc));
    final first = cache();
    final leases = await Future.wait(
        [first.prepare(doc, 'test'), first.prepare(doc, 'test')]);
    expect(requests.length, 5);
    for (final lease in leases) {
      lease.release();
    }
    remote.clear();
    requests.clear();
    final restarted = cache();
    final lease = await restarted.prepare(doc, 'test');
    expect(requests, isEmpty);
    expect(await File(lease.pagePath).exists(), isTrue);
    lease.release();
  });

  test('only B changes; missing new revision never uses old B', () async {
    final service = cache();
    final docs = [document('a'), document('b'), document('c')];
    for (final doc in docs) {
      remote.addAll(fixture(doc));
      (await service.prepare(doc, 'test')).release();
    }
    requests.clear();
    final updated = document('b', revision: 2);
    await expectLater(
        service.prepare(updated, 'test'), throwsA(isA<HttpException>()));
    remote.addAll(fixture(updated));
    requests.clear();
    for (final doc in [docs[0], updated, docs[2]]) {
      (await service.prepare(doc, 'test')).release();
    }
    expect(requests.every((uri) => uri.path.startsWith('/b/v2/')), isTrue);
  });

  test('rejects environment mismatch, traversal, corruption and interruption',
      () async {
    final doc = document('a');
    remote.addAll(fixture(doc));
    final service = cache();
    await expectLater(
        service.prepare(doc, 'production'), throwsFormatException);
    final index = doc.pageUri.resolve('package.json');
    final original = remote[index]!;
    final manifest = jsonDecode(utf8.decode(original));
    manifest['files'][0]['path'] = '../escape.html';
    remote[index] = utf8.encode(jsonEncode(manifest));
    await expectLater(service.prepare(doc, 'test'), throwsFormatException);
    remote[index] = original;
    remote[doc.pageUri.resolve('offline.js')] = [0];
    await expectLater(service.prepare(doc, 'test'), throwsFormatException);
    remote.remove(doc.pageUri.resolve('offline.html'));
    await expectLater(
        service.prepare(doc, 'test'), throwsA(isA<HttpException>()));
    expect(await root.list().toList(), isEmpty);
  });

  test('clear protects active leases then removes unpinned resources',
      () async {
    final doc = document('a');
    remote.addAll(fixture(doc));
    final service = cache(capacity: 0);
    final lease = await service.prepare(doc, 'test');
    await service.clear();
    expect(await File(lease.pagePath).exists(), isTrue);
    lease.release();
    await service.clear();
    expect(await root.list().toList(), isEmpty);
  });

  test('limits concurrent page downloads to two', () async {
    var active = 0;
    var maximum = 0;
    final docs = List.generate(5, (i) => document('page$i'));
    for (final doc in docs) {
      remote.addAll(fixture(doc));
    }
    final service = WebPaywallResourceCache(
        directory: () async => root,
        download: (uri, limit, deadline) async {
          if (uri.path.endsWith('/package.json')) {
            active++;
            if (active > maximum) maximum = active;
          }
          final bytes = await fetch(uri, limit, deadline);
          if (uri.path.endsWith('/page.json')) active--;
          return bytes;
        });
    final leases =
        await Future.wait(docs.map((doc) => service.prepare(doc, 'test')));
    expect(maximum, 2);
    for (final lease in leases) {
      lease.release();
    }
  });

  test('detects corrupt disk cache and downloads only its current version',
      () async {
    final doc = document('a');
    remote.addAll(fixture(doc));
    final service = cache();
    final lease = await service.prepare(doc, 'test');
    await File(lease.pagePath).writeAsString('corrupt');
    lease.release();
    requests.clear();
    final repaired = await service.prepare(doc, 'test');
    expect(requests.length, 5);
    expect(
        await File(repaired.pagePath).readAsString(), '<html>offline</html>');
    repaired.release();
  });
}
