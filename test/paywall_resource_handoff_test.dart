import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';
import 'package:native_paywall/modules/web_paywall/services/web_paywall_resource_verifier.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

/// 阻塞真实目录扫描，确定性验证后台清理不阻塞资源交付。
class GatedDirectory extends Fake implements Directory {
  GatedDirectory(this.base);
  final Directory base;
  bool blocked = false;
  final scanning = Completer<void>();
  final resume = Completer<void>();
  @override
  String get path => base.path;
  @override
  Directory get absolute => base.absolute;
  @override
  Future<Directory> create({bool recursive = false}) =>
      base.create(recursive: recursive);
  @override
  Future<String> resolveSymbolicLinks() => base.resolveSymbolicLinks();
  @override
  Future<Directory> createTemp([String? prefix]) => base.createTemp(prefix);
  @override
  Stream<FileSystemEntity> list(
      {bool recursive = false, bool followLinks = true}) async* {
    if (blocked) {
      if (!scanning.isCompleted) scanning.complete();
      await resume.future;
    }
    yield* base.list(recursive: recursive, followLinks: followLinks);
  }
}

/// 统计是否重复进入 prepare，仍使用生产下载与完整校验。
class CountingCache extends WebPaywallResourceCache {
  CountingCache(Directory root, Map<Uri, List<int>> files)
      : super(
            directory: () async => root,
            download: (uri, limit, deadline) async => files[uri]!);
  int prepares = 0;
  @override
  Future<WebPaywallResourceLease> prepare(
      WebPaywallDocument document, String environment,
      {Duration? timeout, List<int>? manifestBytes}) {
    prepares++;
    return super.prepare(document, environment,
        timeout: timeout, manifestBytes: manifestBytes);
  }
}

void main() {
  final catalog =
      PaywallCatalog(productRefs: ['product'], recommendedRef: 'product');
  late Directory root;
  setUp(() async {
    root = Directory(
        await (await Directory.systemTemp.createTemp('resource-handoff-'))
            .resolveSymbolicLinks());
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
      'slow prune does not delay delivery; renewed lease survives manual clear',
      () async {
    final directory = GatedDirectory(Directory('${root.path}/cache'));
    final doc = fixtures.document('prune');
    final files = fixtures.fixture(doc);
    final cache = WebPaywallResourceCache(
        directory: () async => directory,
        capacityBytes: 0,
        download: (uri, limit, deadline) async {
          directory.blocked = true;
          return files[uri]!;
        });
    final first =
        await cache.prepare(doc, 'test').timeout(const Duration(seconds: 5));
    await directory.scanning.future;
    var cleared = false;
    final clearing = cache.clear().then((_) {
      cleared = true;
    });
    final second = await cache.prepare(doc, 'test');
    first.release();
    expect(cleared, isFalse);
    directory.resume.complete();
    await clearing;
    expect(await File(second.pagePath).exists(), isTrue);
    second.release();
    await cache.clear();
    expect(await second.directory.exists(), isFalse);
  });

  test('loader transfers lease through archive without preparing source twice',
      () async {
    final doc = fixtures.document('handoff');
    final files = fixtures.fixture(doc);
    final cache = CountingCache(Directory('${root.path}/cache'), files);
    WebPaywallResourceLease? held;
    final loader = WebPaywallPackageLoader(
        resourceCache: cache,
        fetch: (uri) async => utf8.decode(files[uri]!),
        onPrepared: (_, lease) {
          held = lease;
        });
    final loaded = await loader.load(doc.pageUri,
        environment: 'test',
        allowedOrigins: {'https://example.com'},
        catalog: catalog);
    final archive = PaywallPackageArchive(
        directory: () async => Directory('${root.path}/archive'),
        environment: 'test',
        allowedOrigins: {'https://example.com'},
        catalog: () => catalog,
        cache: cache);
    try {
      await cache.clear();
      expect(await File(held!.pagePath).exists(), isTrue);
      final saved = await archive.archive(loaded, resource: held);
      expect(cache.prepares, 1);
      expect(held!.isReleased, isFalse);
      await cache.verifyDirectory(saved.localDirectory!, doc, 'test');
      // 新进程读取仍要完整校验，不沿用本次交接的成功结果。
      await File('${saved.localDirectory!.path}/offline.js')
          .writeAsString('corrupt');
      await expectLater(
          archive.open(WebPaywallPackage.identity(doc)), throwsFormatException);
    } finally {
      held?.release();
      await cache.clear();
    }
  });

  test(
      'borrowed source still rejects corruption, wrong environment and escaped links',
      () async {
    final doc = fixtures.document('invalid-handoff');
    final files = fixtures.fixture(doc);
    final cache = CountingCache(Directory('${root.path}/cache'), files);
    final lease = await cache.prepare(doc, 'test');
    PaywallPackageArchive archive(String name, String environment) =>
        PaywallPackageArchive(
            directory: () async => Directory('${root.path}/$name'),
            environment: environment,
            allowedOrigins: {'https://example.com'},
            catalog: () => catalog,
            cache: cache);
    try {
      await expectLater(
          archive('wrong-env', 'production').archive(doc, resource: lease),
          throwsFormatException);
      final js = File('${lease.directory.path}/offline.js');
      final original = await js.readAsBytes();
      await js.writeAsBytes(List<int>.filled(original.length, 0));
      await expectLater(
          archive('corrupt', 'test').archive(doc, resource: lease),
          throwsFormatException);
      final outside = File('${root.path}/outside.js');
      await outside.writeAsBytes(original);
      await js.delete();
      await Link(js.path).create(outside.path);
      await expectLater(
          archive('escaped', 'test').archive(doc, resource: lease),
          throwsA(isA<FileSystemException>()));
      await Link(js.path).delete();
      await js.writeAsBytes(original);
      await expectLater(
          archive('cancelled', 'test')
              .archive(doc, resource: lease, isCurrent: () => false),
          throwsStateError);
      expect(lease.isReleased, isFalse);
    } finally {
      lease.release();
      await cache.clear();
    }
    await expectLater(archive('released', 'test').archive(doc, resource: lease),
        throwsStateError);
  });

  test(
      'large disk verification leaves caller isolate responsive and still detects corruption',
      () async {
    final doc = fixtures.document('large');
    final files = fixtures.fixture(doc);
    final bytes = Uint8List(32 * 1024 * 1024);
    final metadata =
        jsonDecode(utf8.decode(files[doc.pageUri.resolve('package.json')]!))
            as Map<String, dynamic>;
    (metadata['files'] as List).add({
      'path': 'large.bin',
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString()
    });
    for (final entry in files.entries) {
      await File('${root.path}/${entry.key.pathSegments.last}')
          .writeAsBytes(entry.value);
    }
    await File('${root.path}/large.bin').writeAsBytes(bytes);
    await File('${root.path}/package.json').writeAsString(jsonEncode(metadata));
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      ticks++;
    });
    try {
      await WebPaywallResourceVerifier.verify(
          root.path, WebPaywallPackage.identity(doc), 'test');
      expect(ticks, greaterThan(2));
      await File('${root.path}/large.bin').writeAsBytes([1]);
      await expectLater(
          WebPaywallResourceVerifier.verify(
              root.path, WebPaywallPackage.identity(doc), 'test'),
          throwsFormatException);
    } finally {
      timer.cancel();
    }
  });
}
