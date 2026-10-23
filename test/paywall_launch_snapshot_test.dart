import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;
import 'paywall_query_runtime_test.dart' show RealHttpOverrides;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'launch snapshot freezes revisions, evicts only valid unmatched responses and isolates versions',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final root = Directory(await (await Directory.systemTemp
                    .createTemp('launch-snapshot-'))
                .resolveSymbolicLinks());
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final origin = 'http://127.0.0.1:${server.port}';
            final catalog = PaywallCatalog(
                productRefs: ['product'], recommendedRef: 'product');
            var revision = 1, queries = 0;
            var empty = false, invalid = false, broken = false;
            final clients = <PaywallClient>[];
            final channel = TestDefaultBinaryMessengerBinding
                .instance.defaultBinaryMessenger;
            channel.setMockMethodCallHandler(
                const MethodChannel('native_paywall/resources'),
                (call) async => root.path);
            final subscription = server.listen((request) async {
              if (request.uri.path == '/query') {
                queries++;
                await utf8.decoder.bind(request).join();
                request.response.write(jsonEncode({
                  'code': invalid ? '500' : '200',
                  'data': empty
                      ? []
                      : [
                          {
                            'positionKey': 'entry',
                            'matched': true,
                            'h5Url': '$origin/page/v$revision/index.html',
                            'displayModeKey': 'halfSheet'
                          }
                        ]
                }));
              } else {
                final version =
                    int.tryParse(request.uri.path.split('/')[2].substring(1)) ??
                        1;
                final doc = WebPaywallDocument.parse({
                  'kind': 'web-paywall',
                  'bridgeVersion': 2,
                  'documentId': 'page',
                  'revision': version,
                  'pageUrl': '$origin/page/v$version/index.html',
                  'catalogKey': 'default',
                  'productRefs': ['product'],
                  'initialProductRef': 'product'
                }, allowedOrigins: {
                  origin
                }, catalog: catalog, developmentHTTPOrigin: origin);
                final data = fixtures
                    .fixture(doc)[Uri.parse('$origin${request.uri.path}')];
                if (broken || data == null) {
                  request.response.statusCode = 404;
                } else {
                  request.response.add(data);
                }
              }
              await request.response.close();
            });
            Future<PaywallClient> create({String version = '1'}) async {
              final client = PaywallClient.query(
                  query: PaywallQueryConfiguration(
                      endpoint: Uri.parse('$origin/query'),
                      cacheNamespace: 'snapshot',
                      allowedOrigins: {origin},
                      placements: {'entry': 'settings'},
                      developmentHTTPOrigin: origin,
                      environment: () async => WebPaywallEnvironment(
                          os: 'iOS',
                          language: 'en',
                          deviceModel: 'phone',
                          country: 'USA',
                          appVersion: version)),
                  catalog: () => catalog,
                  storage: PaywallStorage(directory: () async => root));
              clients.add(client);
              await client.reportAttribution(channel: 'organic');
              return client;
            }

            Future<void> waitIndex(bool Function(List<Map>) matches) async {
              for (var i = 0; i < 200; i++) {
                final values = <Map>[];
                await for (final file in root.list(recursive: true)) {
                  if (file is File && file.path.endsWith('/index.json')) {
                    values.add(jsonDecode(await file.readAsString()) as Map);
                  }
                }
                if (matches(values)) return;
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              fail('Snapshot index did not reach expected state');
            }

            try {
              final first = await create();
              expect((await first.resolve('settings'))!.document.revision, 1);
              expect(first.cachedPlacement('settings')!.document.localDirectory,
                  isNotNull);
              await first.waitForQueryUpdate();
              first.dispose();
              revision = 2;
              final second = await create();
              expect((await second.resolve('settings'))!.document.revision, 1);
              await second.waitForQueryUpdate();
              expect((await second.resolve('settings'))!.document.revision, 1);
              await second.waitForQueryUpdate();
              second.dispose();
              final third = await create();
              expect((await third.resolve('settings'))!.document.revision, 2);
              await Future<void>.delayed(const Duration(milliseconds: 100));
              invalid = true;
              await third.waitForQueryUpdate();
              third.dispose();
              final failed = await create(version: 'failure');
              await expectLater(
                  failed.resolve('settings'), throwsFormatException);
              await expectLater(
                  failed.resolve('settings'), throwsFormatException);
              await failed.waitForQueryUpdate();
              failed.dispose();
              final fourth = await create();
              expect((await fourth.resolve('settings'))!.document.revision, 2);
              await Future<void>.delayed(const Duration(milliseconds: 100));
              invalid = false;
              broken = true;
              revision = 3;
              await fourth.waitForQueryUpdate();
              fourth.dispose();
              final fifth = await create();
              expect((await fifth.resolve('settings'))!.document.revision, 2);
              await Future<void>.delayed(const Duration(milliseconds: 100));
              empty = true;
              broken = false;
              await fifth.waitForQueryUpdate();
              fifth.dispose();
              final sixth = await create();
              expect((await sixth.resolve('settings'))!.document.revision, 2);
              await waitIndex((values) =>
                  values.every((v) => (v['placements'] as Map).isEmpty));
              expect((await sixth.resolve('settings'))!.document.revision, 2);
              await sixth.waitForQueryUpdate();
              sixth.dispose();
              final seventh = await create();
              expect(await seventh.resolve('settings'), isNull);
              await seventh.waitForQueryUpdate();
              seventh.dispose();
              final upgraded = await create(version: '2');
              expect(await upgraded.resolve('settings'), isNull);
              expect(queries, 9);
            } finally {
              for (final client in clients) {
                client.dispose();
              }
              await subscription.cancel();
              await server.close(force: true);
              await Future<void>.delayed(const Duration(milliseconds: 100));
              channel.setMockMethodCallHandler(
                  const MethodChannel('native_paywall/resources'), null);
              await root.delete(recursive: true);
            }
          }, RealHttpOverrides()));
}
