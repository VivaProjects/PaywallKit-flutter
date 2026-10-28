import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'paywall_query_runtime_test.dart' show RealHttpOverrides;
import 'web_paywall_resource_cache_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'default query batch retains shared resource through callback failure and releases at end',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final root = Directory(await (await Directory.systemTemp
                    .createTemp('query-ownership-'))
                .resolveSymbolicLinks());
            final channel = const MethodChannel('native_paywall/resources');
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, (_) async => root.path);
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final doc = fixtures.document('shared');
            final files = fixtures.fixture(doc);
            final slow = fixtures.document('slow');
            final slowFiles = fixtures.fixture(slow);
            final slowStarted = Completer<void>();
            final resumeSlow = Completer<void>();
            var requests = 0;
            server.listen((request) async {
              requests++;
              final isSlow = request.uri.path.contains('/slow/');
              if (isSlow) {
                if (!slowStarted.isCompleted) slowStarted.complete();
                await resumeSlow.future;
              }
              request.response.add(isSlow
                  ? slowFiles[
                      slow.pageUri.resolve(request.uri.pathSegments.last)]!
                  : files[doc.pageUri.resolve(request.uri.pathSegments.last)]!);
              await request.response.close();
            });
            final origin = 'http://127.0.0.1:${server.port}';
            final response = PaywallQueryResponse(
                placements: {
                  'first': 'first',
                  'alias': 'alias',
                  'slow': 'slow'
                },
                allowedOrigins: {
                  origin
                },
                developmentHTTPOrigin: origin,
                catalog: () => PaywallCatalog(
                    productRefs: ['product'], recommendedRef: 'product'));
            final request = PaywallConfigurationRequest.query(
                endpoint: Uri.parse('https://example.com/query'),
                environment: const WebPaywallEnvironment(
                    os: 'iOS',
                    language: 'en',
                    deviceModel: 'phone',
                    country: 'USA',
                    appVersion: '1'),
                channelKey: 'organic');
            final leases = <WebPaywallResourceLease>[];
            final unavailable = <String>{};
            try {
              final loading = response.load(
                  jsonEncode({
                    'code': '200',
                    'data': [
                      for (final name in ['first', 'alias', 'slow'])
                        {
                          'positionKey': name,
                          'matched': true,
                          'h5Url':
                              '$origin/${name == 'slow' ? 'slow' : 'shared'}/v1/index.html'
                        }
                    ]
                  }),
                  request,
                  onUnavailable: unavailable.addAll,
                  onPage: (name, doc, mode) async {
                fail('Default loader lost prepared resource');
              }, onPreparedPage: (name, document, mode, resource) async {
                if (name == 'slow') return;
                leases.add(resource);
                expect(resource.isReleased, isFalse);
                await WebPaywallResourceCache.shared.clear();
                expect(await File(resource.pagePath).exists(), isTrue);
                if (name == 'first')
                  throw StateError('Simulated archive failure');
              });
              await slowStarted.future;
              for (var i = 0;
                  i < 100 && (leases.length < 2 || !leases.first.isReleased);
                  i++) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              expect(leases, hasLength(2));
              expect(leases.first.isReleased, isTrue,
                  reason:
                      'Completed package must not remain pinned by unrelated download');
              resumeSlow.complete();
              await loading;
              expect(identical(leases.first, leases.last), isTrue);
              expect(leases.every((lease) => lease.isReleased), isTrue);
              expect(unavailable, {'first'});
              expect(requests, 10);
              await WebPaywallResourceCache.shared.clear();
              expect(await leases.first.directory.exists(), isFalse);
            } finally {
              if (!resumeSlow.isCompleted) resumeSlow.complete();
              await WebPaywallResourceCache.shared.clear();
              await server.close(force: true);
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, null);
              await root.delete(recursive: true);
            }
          }, RealHttpOverrides()));
}
