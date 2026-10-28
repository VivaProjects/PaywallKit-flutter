import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:native_paywall/modules/paywall_client/services/paywall_query_package_batch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

/// 下载入口可观测，失败立即返回，用于验证归档等待期间的预取上限。
class PipelineLoader extends WebPaywallPackageLoader {
  final started = <String>[];
  String? failing;
  @override
  Future<WebPaywallDocument> load(Uri uri,
      {required String environment,
      required Set<String>? allowedOrigins,
      required PaywallCatalog catalog,
      String? developmentHTTPOrigin}) async {
    final name = uri.pathSegments.first;
    started.add(name);
    if (name == failing) throw const FormatException('bad package');
    return fixtures.document(name);
  }
}

void main() {
  final request = PaywallConfigurationRequest.query(
      endpoint: Uri.parse('https://example.com/query'),
      environment: const WebPaywallEnvironment(
          os: 'iOS',
          language: 'en',
          deviceModel: 'phone',
          country: 'USA',
          appVersion: '1'),
      channelKey: 'organic');
  String response(List<String> names) => jsonEncode({
        'code': '200',
        'data': [
          for (final name in names)
            {
              'positionKey': name,
              'matched': true,
              'h5Url': 'https://example.com/$name/index.html'
            }
        ]
      });
  PaywallQueryResponse query(PipelineLoader loader, List<String> names) =>
      PaywallQueryResponse(
          placements: {for (final name in names) name: name},
          allowedOrigins: {'https://example.com'},
          catalog: () => PaywallCatalog(
              productRefs: ['product'], recommendedRef: 'product'),
          loader: loader);

  test('batch exit waits for late prefetch and releases its resource',
      () async {
    final batch = PaywallQueryPackageBatch(['late'], PipelineLoader());
    final resume = Completer<void>();
    final doc = fixtures.document('late');
    final lease =
        WebPaywallResourceLease(Directory('/unused/pipeline-test'), () {});
    batch.load('late', (_) async {
      await resume.future;
      batch.resources[doc] = lease;
      return doc;
    });
    var exited = false;
    final close = () async {
      await batch.settle();
      batch.dispose();
      exited = true;
    }();
    await Future<void>.delayed(Duration.zero);
    expect(exited, isFalse);
    resume.complete();
    await close;
    expect(lease.isReleased, isTrue);
    expect(batch.resources, isEmpty);
  });

  test('each worker prefetches only one package while archive is blocked',
      () async {
    final names = ['a', 'b', 'c', 'd', 'e', 'f'];
    final loader = PipelineLoader();
    final resume = Completer<void>();
    final entered = Completer<void>();
    final delivered = <String>[];
    String? preferred;
    final task = query(loader, names).load(response(names), request,
        preferredPlacement: () => preferred,
        onUnavailable: (_) {},
        onPage: (name, doc, mode) async {
          delivered.add(name);
          if (delivered.length == 2) entered.complete();
          if (name == 'a' || name == 'b') await resume.future;
        });
    try {
      await entered.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(loader.started, ['a', 'b', 'c', 'd']);
      expect(delivered.toSet(), {'a', 'b'});
      preferred = 'f';
    } finally {
      resume.complete();
      await task;
    }
    expect(delivered.toSet(), names.toSet());
    expect(delivered.length, names.length);
    expect(loader.started.indexOf('f'), lessThan(loader.started.indexOf('e')));
  });

  test('early prefetch failure is handled and later packages still deliver',
      () async {
    final names = ['a', 'b', 'c', 'd', 'e'];
    final loader = PipelineLoader()..failing = 'c';
    final resume = Completer<void>();
    final entered = Completer<void>();
    final delivered = <String>[];
    final unavailable = <String>{};
    var failures = 0;
    final task = query(loader, names).load(response(names), request,
        onUnavailable: unavailable.addAll,
        onFailure: () => failures++,
        onPage: (name, doc, mode) async {
          delivered.add(name);
          if (delivered.length == 2) entered.complete();
          if (name == 'a' || name == 'b') await resume.future;
        });
    try {
      await entered.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(failures, 1);
      expect(unavailable, isEmpty); // 失败仍按原点位交付路径通知。
    } finally {
      resume.complete();
      await task;
    }
    expect(unavailable, {'c'});
    expect(delivered.toSet(), {'a', 'b', 'd', 'e'});
  });
}
