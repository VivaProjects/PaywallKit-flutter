import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';

class RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'query runtime owns attribution and storefront invalidation with lifecycle cleanup',
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
                    endpoint: Uri.parse('$origin/query'),
                    cacheNamespace: 'app',
                    allowedOrigins: {origin},
                    placements: {},
                    developmentHTTPOrigin: origin,
                    storefrontChanges: storefront.stream,
                    environment: () async => WebPaywallEnvironment(
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
              expect(requests.single['channelKey'], 'paid');
              final changed = observed.stream
                  .firstWhere((value) => value['channelKey'] == 'other');
              await client.reportAttribution(channel: 'other');
              await changed.timeout(const Duration(seconds: 5));
              country = 'CAN';
              final moved = observed.stream.firstWhere(
                  (value) => (value['conditions'] as Map)['country'] == 'CAN');
              storefront.add('CAN');
              await moved.timeout(const Duration(seconds: 5));
              expect(requests.last['channelKey'], 'other');
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
}
