import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:native_paywall/modules/paywall_client/models/paywall_http_failure.dart';

// SDK 已依赖 crypto；这里用于生成与真实校验器一致的完整包夹具。
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';

void main() {
  late Directory root;
  late _Packages packages;
  late PaywallStorage storage;
  final clients = <PaywallClient>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('paywall-query-');
    root = Directory(await root.resolveSymbolicLinks());
    packages = _Packages(root);
    storage = PaywallStorage(directory: () async => root);
  });
  tearDown(() async {
    for (final client in clients) {
      client.dispose();
    }
    clients.clear();
    PaywallLogging.mode = PaywallLoggingMode.automatic;
    await root.delete(recursive: true);
  });

  /// 相同命名空间模拟同次进程，不同 Client 共享后台任务。
  PaywallClient client(
    Future<String> Function() fetch, {
    Future<void> Function(Future<void>)? online,
    void Function(PaywallQueryUpdateDiagnostic)? diagnostic,
  }) {
    final value = PaywallClient.query(
      query: PaywallQueryConfiguration(
        endpoint: Uri.parse('https://example.com/query'),
        cacheNamespace: root.path,
        allowedOrigins: null,
        placements: const {'settings': 'settings', 'result': 'result'},
        environment: () async => _environment,
        packageLoader: packages,
        fetch: (_) => fetch(),
        onUpdateDiagnostic: diagnostic,
        waitUntilNetworkAvailableCancellable: online,
      ),
      catalog: () => _catalog,
      storage: storage,
    );
    clients.add(value);
    return value;
  }

  /// 归因预先明确，回归不依赖真实 SDK 或计时器。
  Future<void> ready(PaywallClient value) =>
      value.reportAttribution(channel: 'organic');

  test('临时 HTTP 故障最多三次，恢复后仅报告一次完成', () async {
    var attempts = 0;
    final reports = <PaywallQueryUpdateDiagnostic>[];
    final value = client(() async {
      if (++attempts < 3) throw PaywallHttpFailure(503);
      return _response(1);
    }, diagnostic: reports.add);
    await ready(value);
    await value.waitForQueryUpdate();
    expect(attempts, 3);
    expect(reports.single.updatedPlacements, 1);
    expect(reports.single.failures, 0);
  });

  test('单包临时失败重试后完整归档，已有版本仍供本次使用', () async {
    final first = client(() async => _response(1));
    await ready(first);
    await first.waitForQueryUpdate();
    first.dispose();
    clients.remove(first);
    packages.transientFailures = 1;
    final reports = <PaywallQueryUpdateDiagnostic>[];
    final value = client(() async => _response(2), diagnostic: reports.add);
    await ready(value);
    await value.waitForQueryUpdate();
    expect(packages.loads, 3);
    expect(reports.single.updatedPlacements, 1);
    expect(reports.single.failures, 0);
    expect(value.cachedPlacement('settings')!.document.revision, 1);
  });

  test('权限和无效数据不重试，最终失败只报告一次', () async {
    for (final error in [
      PaywallHttpFailure(403),
      const FormatException('bad')
    ]) {
      var attempts = 0;
      final reports = <PaywallQueryUpdateDiagnostic>[];
      final value = client(() async {
        attempts++;
        throw error;
      }, diagnostic: reports.add);
      await ready(value);
      await value.waitForQueryUpdate();
      expect(attempts, 1);
      expect(reports.single.failed, isTrue);
      value.dispose();
      clients.remove(value);
    }
  });

  test('同版本无需更新，展示方式变化计为更新', () async {
    for (var run = 0; run < 3; run++) {
      final reports = <PaywallQueryUpdateDiagnostic>[];
      final value = client(
          () async => run == 2
              ? _response(1).replaceAll('fullScreen', 'halfSheet')
              : _response(1),
          diagnostic: reports.add);
      await ready(value);
      await value.waitForQueryUpdate();
      expect(reports.single.updatedPlacements, run == 1 ? 0 : 1);
      expect(reports.single.failures, 0);
      value.dispose();
      clients.remove(value);
    }
  });

  test('三秒入口兜底冻结，迟到包仅供下次启动，预加载不抢先超时', () async {
    final response = Completer<String>();
    final value = client(() => response.future);
    await ready(value);
    final pending = value.waitForQueryUpdate();
    expect(await value.resolveForPresentation('result'), isNull);
    response.complete(_response(2, result: true));
    await pending;
    expect(value.cachedPlacement('result'), isNull);
    expect(value.cachedPlacement('settings'), isNotNull);
    expect(await value.resolve('result'), isNull);
    value.dispose();
    clients.remove(value);
    final next = client(() async => _response(3));
    await next.restoreQuery();
    expect(next.cachedPlacement('result')!.document.revision, 2);
  });

  test('取消退避立即结束且不通知；日志关闭时保持静默', () async {
    final attempted = Completer<void>();
    final reports = <PaywallQueryUpdateDiagnostic>[];
    var attempts = 0;
    final value = client(() async {
      attempts++;
      attempted.complete();
      throw const SocketException('offline');
    }, diagnostic: reports.add);
    await ready(value);
    final pending = value.waitForQueryUpdate();
    await attempted.future;
    value.dispose();
    clients.remove(value);
    await pending.timeout(const Duration(seconds: 1));
    expect(attempts, 1);
    expect(reports, isEmpty);
    PaywallLogging.mode = PaywallLoggingMode.disabled;
    final muted = client(() async => _response(1), diagnostic: reports.add);
    await ready(muted);
    await muted.waitForQueryUpdate();
    expect(reports, isEmpty);
  });

  test('共享 Client 只提示一次，单包损坏统计失败而非更新', () async {
    packages.fail = true;
    final reports = <PaywallQueryUpdateDiagnostic>[];
    final a = client(() async => _response(1), diagnostic: reports.add);
    final b = client(() async => _response(1), diagnostic: reports.add);
    await ready(a);
    await Future.wait([a.waitForQueryUpdate(), b.waitForQueryUpdate()]);
    expect(reports.single.updatedPlacements, 0);
    expect(reports.single.failures, 1);
  });

  test('两次启动：已有版本冻结，缺失点位即时可用，后台新版本下次生效', () async {
    final first = client(() async => _response(1));
    await ready(first);
    await first.waitForQueryUpdate();
    expect(first.cachedPlacement('settings')!.document.revision, 1);
    first.dispose();
    clients.remove(first);

    final second = client(() async => _response(2, result: true));
    await ready(second);
    await second.waitForQueryUpdate();
    expect(second.cachedPlacement('settings')!.document.revision, 1);
    expect((await second.resolve('result'))!.document.revision, 2);
    second.dispose();
    clients.remove(second);

    final third = client(() async => throw const SocketException('offline'));
    await third.restoreQuery();
    expect(third.cachedPlacement('settings')!.document.revision, 2);
    expect(third.cachedPlacement('settings')!.environment.os, 'Android');
    expect(third.cachedPlacement('settings')!.environment.isPad, isTrue);
  });

  test('合法空响应删除下次启动索引，本次缓存继续使用', () async {
    final first = client(() async => _response(1));
    await ready(first);
    await first.waitForQueryUpdate();
    first.dispose();
    clients.remove(first);
    final second = client(() async => jsonEncode({'code': '200', 'data': []}));
    await ready(second);
    await second.waitForQueryUpdate();
    expect(second.cachedPlacement('settings'), isNotNull);
    second.dispose();
    clients.remove(second);
    final third = client(() async => throw StateError('not requested'));
    await third.restoreQuery();
    expect(third.cachedPlacement('settings'), isNull);
  });

  test('网络、信封解析和包下载失败均保留旧持久缓存', () async {
    final first = client(() async => _response(1));
    await ready(first);
    await first.waitForQueryUpdate();
    first.dispose();
    clients.remove(first);
    for (final failure in ['network', 'envelope', 'package']) {
      packages.fail = failure == 'package';
      final value = client(() async {
        if (failure == 'network') throw const SocketException('offline');
        return failure == 'envelope' ? '{broken' : _response(2);
      });
      await ready(value);
      await value.waitForQueryUpdate();
      expect(value.cachedPlacement('settings')!.document.revision, 1);
      value.dispose();
      clients.remove(value);
    }
    final restored = client(() async => _response(3));
    await restored.restoreQuery();
    expect(restored.cachedPlacement('settings')!.document.revision, 1);
  });

  for (final independent in [false, true]) {
    test('完整旧快照离线迁移并保留适配参数 independent=$independent', () async {
      final namespace = '${root.path}.test';
      final scope = independent
          ? jsonEncode([
              namespace,
              'https://example.com/query',
              '1',
              'Android',
              'en',
            ])
          : namespace;
      final old = PaywallPackageArchive(
          directory: () => storage.folder('query_snapshots', scope),
          environment: 'test',
          catalog: () => _catalog,
          allowedOrigins: null);
      final doc = await packages.load(
          Uri.parse('https://example.com/settings/7/index.html'),
          environment: 'test',
          allowedOrigins: null,
          catalog: _catalog);
      await old.archive(doc);
      final request = PaywallConfigurationRequest.query(
          endpoint: Uri.parse('https://example.com/query'),
          environment: _environment,
          channelKey: 'organic');
      final record = {
        'environment': _environment.toPayload(),
        'requestIdentity': request.identity(namespace),
        if (independent) ...{
          'requestBody': request.body,
          'document': WebPaywallPackage.identity(doc),
          'presentation': 'fullScreen',
        } else
          'configuration': PaywallQueryResponse.configurationFor(
              'settings', doc, 'fullScreen'),
      };
      await File('${(await old.directory()).path}/index.json')
          .writeAsString(jsonEncode({
        'version': 1,
        'environment': 'test',
        independent ? 'records' : 'placements': {'settings': record},
      }));
      var requests = 0;
      final value = client(() async {
        requests++;
        return _response(8);
      });
      await value.restoreQuery();
      expect(requests, 0);
      final restored = value.cachedPlacement('settings')!;
      expect(restored.document.revision, 7);
      expect(restored.environment.os, 'Android');
      expect(restored.environment.isPad, isTrue);
    });
  }

  test('两个回退域共用一次请求，迟到归因和再次准备不追加查询', () async {
    var calls = 0;
    Future<String> fetch() async {
      calls++;
      return _response(1, result: true);
    }

    final a = client(fetch), b = client(fetch);
    await ready(a);
    await Future.wait([a.waitForQueryUpdate(), b.waitForQueryUpdate()]);
    await b.reportAttribution(channel: 'late-channel');
    await a.preloadConfiguration();
    await b.resolve('result');
    expect(calls, 1);
    expect(a.cachedPlacement('settings')!.clientIdentity, a.identity);
    expect(b.cachedPlacement('settings')!.clientIdentity, b.identity);
  });

  test('离线不发送请求，恢复后只执行一次；释放能结束网络等待', () async {
    final gate = Completer<void>();
    final waiting = Completer<void>();
    var calls = 0;
    final value = client(
      () async {
        calls++;
        return _response(1);
      },
      online: (cancel) async {
        if (!waiting.isCompleted) waiting.complete();
        await Future.any([
          gate.future,
          cancel.then((_) => throw StateError('cancelled')),
        ]);
      },
    );
    await ready(value);
    final update = value.waitForQueryUpdate();
    await waiting.future;
    expect(calls, 0);
    gate.complete();
    await update;
    expect(calls, 1);
    value.dispose();
    clients.remove(value);

    final cancelled = Completer<void>();
    final stopped = client(
      () async {
        calls++;
        return _response(2);
      },
      online: (cancel) async {
        if (!cancelled.isCompleted) cancelled.complete();
        await cancel;
        throw StateError('cancelled');
      },
    );
    final pending = stopped.waitForQueryUpdate();
    await cancelled.future;
    stopped.dispose();
    clients.remove(stopped);
    await pending;
    expect(calls, 1);
  });
}

const _environment = WebPaywallEnvironment(
  os: 'Android',
  isPad: true,
  language: 'en',
  deviceModel: 'Android',
  country: 'USA',
  appVersion: '1',
);
final _catalog = PaywallCatalog(productRefs: ['plan'], recommendedRef: 'plan');

/// 发布地址携带版本用于隔离资源，点位名称仍保持稳定。
String _response(int revision, {bool result = false}) => jsonEncode({
      'code': '200',
      'data': [
        for (final name in ['settings', if (result) 'result'])
          {
            'positionKey': name,
            'matched': true,
            'h5Url': 'https://example.com/$name/$revision/index.html',
            'displayModeKey': 'fullScreen',
          },
      ],
    });

/// 用最小完整发布包覆盖真实文件大小和摘要校验，不借用网络下载。
class _Packages extends Fake implements WebPaywallPackageLoader {
  _Packages(this.root);
  final Directory root;
  bool fail = false;
  int transientFailures = 0;
  int loads = 0;
  @override
  Future<WebPaywallDocument> load(
    Uri uri, {
    required String environment,
    required Set<String>? allowedOrigins,
    required PaywallCatalog catalog,
    String? developmentHTTPOrigin,
  }) async {
    loads++;
    if (transientFailures-- > 0) throw PaywallHttpFailure(503);
    if (fail) throw const FormatException('Broken package');
    final name = uri.pathSegments[0], revision = int.parse(uri.pathSegments[1]);
    final directory = Directory('${root.path}/fixture-$name-$revision');
    await directory.create(recursive: true);
    final identity = <String, dynamic>{
      'kind': 'web-paywall',
      'bridgeVersion': 2,
      'documentId': name,
      'revision': revision,
      'pageUrl': uri.toString(),
      'catalogKey': 'default',
      'productRefs': ['plan'],
      'initialProductRef': 'plan',
    };
    final files = <Map<String, dynamic>>[];
    for (final file in [
      'offline.html',
      'offline.js',
      'content.json',
      'page.json',
    ]) {
      final bytes = utf8.encode(
        file.endsWith('.json') ? '{}' : 'fixture $revision',
      );
      await File('${directory.path}/$file').writeAsBytes(bytes);
      files.add({
        'path': file,
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      });
    }
    await File('${directory.path}/package.json').writeAsString(
      jsonEncode({
        'formatVersion': 1,
        'runtimeEnvironment': environment,
        'document': identity,
        'entry': 'offline.html',
        'files': files,
      }),
    );
    return WebPaywallDocument.parse(
      identity,
      allowedOrigins: allowedOrigins,
      catalog: catalog,
    ).withLocalDirectory(directory);
  }
}
