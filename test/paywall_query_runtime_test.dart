import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';

class RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'query runtime freezes one request despite attribution storefront and force refresh',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final root = Directory(await (await Directory.systemTemp
                    .createTemp('paywall-query-runtime-'))
                .resolveSymbolicLinks());
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final origin = 'http://127.0.0.1:${server.port}';
            final requests = <Map<String, dynamic>>[];
            final observed = StreamController<Map<String, dynamic>>.broadcast();
            final stream = server.listen((request) async {
              final body = jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
              requests.add(body);
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'code': '200', 'data': []}));
              await request.response.close();
              observed.add(body);
            });
            final storefront = StreamController<String>.broadcast();
            var country = 'USA';
            final client = PaywallClient.query(
                query: PaywallQueryConfiguration(
                    remoteUpdatesEnabled: true,
                    endpoint: Uri.parse('$origin/query'),
                    cacheNamespace: 'app',
                    allowedOrigins: {origin},
                    placements: {},
                    developmentHTTPOrigin: origin,
                    storefrontChanges: storefront.stream,
                    environment: () async => WebPaywallEnvironment(
                        os: 'iOS',
                        language: 'en',
                        deviceModel: 'phone',
                        country: country,
                        appVersion: '1')),
                catalog: () => PaywallCatalog(
                    productRefs: ['product'], recommendedRef: 'product'),
                storage: PaywallStorage(directory: () async => root));
            try {
              await client.reportAttribution(channel: 'paid');
              expect(await client.resolve('missing'), isNull);
              expect(requests.single.containsKey('channelKey'), isFalse);
              expect(requests.single['conditions']['channel'], 'paid');
              await client.reportAttribution(channel: 'other');
              country = 'CAN';
              storefront.add('CAN');
              await client.refresh();
              await client.resolve('missing');
              await Future<void>.delayed(const Duration(milliseconds: 20));
              expect(requests, hasLength(1));
              client.dispose();
              await Future<void>.delayed(const Duration(milliseconds: 20));
              expect(storefront.hasListener, isFalse);
            } finally {
              client.dispose();
              await storefront.close();
              await observed.close();
              await stream.cancel();
              await server.close(force: true);
              await Future<void>.delayed(const Duration(milliseconds: 20));
              await root.delete(recursive: true);
            }
          }, RealHttpOverrides()));
  test('dispose wakes configuration waiters while network gate is pending',
      () async {
    final root = Directory(
        await (await Directory.systemTemp.createTemp('query-offline-'))
            .resolveSymbolicLinks());
    final entered = Completer<void>(), online = Completer<void>();
    final client = PaywallClient.query(
        query: PaywallQueryConfiguration(
            remoteUpdatesEnabled: true,
            endpoint: Uri.parse('https://example.com/query'),
            cacheNamespace: 'offline',
            allowedOrigins: {'https://example.com'},
            placements: {'entry': 'settings'},
            waitUntilNetworkAvailable: () {
              if (!entered.isCompleted) entered.complete();
              return online.future;
            },
            environment: () async => const WebPaywallEnvironment(
                os: 'iOS',
                language: 'en',
                deviceModel: 'phone',
                country: 'USA',
                appVersion: '1')),
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        storage: PaywallStorage(directory: () async => root));
    try {
      await client.reportAttribution(channel: 'organic');
      final result = expectLater(
          client.resolve('settings'), throwsA(PaywallFailure.cancelled));
      await entered.future;
      client.dispose();
      await result;
      online.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } finally {
      client.dispose();
      if (!online.isCompleted) online.complete();
      await root.delete(recursive: true);
    }
  });
}

// 等待联网和失败任务由 Client 持有，展示取消不产生第二个配置请求。
