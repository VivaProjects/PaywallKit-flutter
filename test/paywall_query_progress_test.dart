import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

class ControlledLoader extends WebPaywallPackageLoader {
  final blocked = Completer<WebPaywallDocument>();
  final started = <String>[];
  @override
  Future<WebPaywallDocument> load(Uri uri,
      {required String environment,
      required Set<String>? allowedOrigins,
      required PaywallCatalog catalog,
      String? developmentHTTPOrigin}) async {
    started.add(uri.path);
    if (uri.path.contains('slow')) return blocked.future;
    return fixtures.document('fast');
  }
}

void main() {
  test(
      'fast complete package commits before unrelated slow package and shared URLs load once',
      () async {
    final loader = ControlledLoader();
    final response = PaywallQueryResponse(
        placements: {'slow': 'slow', 'fast': 'fast', 'alias': 'alias'},
        allowedOrigins: {'https://example.com'},
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        loader: loader);
    final received = <String>[];
    final first = Completer<void>();
    final request = PaywallConfigurationRequest.query(
        endpoint: Uri.parse('https://example.com/query'),
        environment: const WebPaywallEnvironment(
            os: 'iOS',
            language: 'en',
            deviceModel: 'phone',
            country: 'USA',
            appVersion: '1'),
        channelKey: 'organic');
    final task = response.transform(
        jsonEncode({
          'code': '200',
          'data': [
            {
              'positionKey': 'slow',
              'matched': true,
              'h5Url': 'https://example.com/slow/index.html'
            },
            {
              'positionKey': 'fast',
              'matched': true,
              'h5Url': 'https://example.com/fast/v1/index.html'
            },
            {
              'positionKey': 'alias',
              'matched': true,
              'h5Url': 'https://example.com/fast/v1/index.html'
            }
          ]
        }),
        request, onPage: (name, doc, mode) async {
      received.add(name);
      if (name == 'fast') first.complete();
    });
    await first.future.timeout(const Duration(seconds: 1));
    expect(received, contains('fast'));
    expect(received, isNot(contains('slow')));
    loader.blocked.complete(fixtures.document('slow'));
    await task;
    expect(received.toSet(), {'fast', 'alias', 'slow'});
    expect(loader.started.where((path) => path.contains('fast')), hasLength(1));
  });
}
