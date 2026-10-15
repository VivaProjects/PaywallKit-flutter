import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_package.dart';
import 'web_paywall_resource_cache_test.dart' as fixtures;

void main() {
  test(
      'shared package selects exact production binding and supports relocated publishing',
      () {
    final doc = fixtures.document('shared');
    final test = WebPaywallPackage.identity(doc);
    final production = {
      ...test,
      'productRefs': ['production-product'],
      'initialProductRef': 'production-product'
    };
    final original = jsonDecode(utf8.decode(
            fixtures.fixture(doc)[doc.pageUri.resolve('package.json')]!))
        as Map<String, dynamic>;
    original.addAll({
      'formatVersion': 2,
      'runtimeEnvironment': 'shared',
      'documents': {'test': test, 'production': production}
    });
    final expected = {
      ...production,
      'pageUrl': 'https://cdn.example.com/new/index.html'
    };
    expect(
        WebPaywallPackage.parse(
                utf8.encode(jsonEncode(original)), expected, 'production')
            .files
            .length,
        4);
    expect(
        () => WebPaywallPackage.parse(
            utf8.encode(jsonEncode(original)), test, 'production'),
        throwsFormatException);
    (original['documents'] as Map).remove('production');
    expect(
        () => WebPaywallPackage.parse(
            utf8.encode(jsonEncode(original)), test, 'test'),
        throwsFormatException);
  });

  test(
      'query loader verifies full resources and isolates malformed matched page',
      () async {
    final root = Directory(
        await (await Directory.systemTemp.createTemp('paywall-query-test-'))
            .resolveSymbolicLinks());
    final doc = fixtures.document('query');
    final remote = fixtures.fixture(doc);
    final cache = WebPaywallResourceCache(
        directory: () async => root,
        download: (uri, limit, deadline) async => remote[uri]!);
    final loader = WebPaywallPackageLoader(
        resourceCache: cache, fetch: (uri) async => utf8.decode(remote[uri]!));
    final transform = PaywallQueryResponse(
        placements: {'good': 'settings', 'bad': 'banner'},
        allowedOrigins: {'https://example.com'},
        catalog: () =>
            PaywallCatalog(productRefs: ['product'], recommendedRef: 'product'),
        loader: loader);
    const environment = WebPaywallEnvironment(
        language: 'en', deviceModel: 'phone', country: '', appVersion: '1');
    final request = PaywallConfigurationRequest.query(
        endpoint: Uri.parse('https://example.com/query'),
        environment: environment,
        channelKey: 'organic');
    try {
      final result = jsonDecode(await transform.transform(
          jsonEncode({
            'code': '200',
            'data': [
              {
                'positionKey': 'bad',
                'matched': true,
                'h5Url': 'https://evil.example.com/index.html'
              },
              {
                'positionKey': 'good',
                'matched': true,
                'h5Url': doc.pageUri.toString(),
                'displayModeKey': 'halfSheet'
              },
            ]
          }),
          request));
      expect(result['placements'], {'settings': 'query'});
      expect(result['presentations'], {'settings': 'halfSheet'});
      expect(result['paywalls']['query']['productRefs'], ['product']);
      await cache.clear();
    } finally {
      await root.delete(recursive: true);
    }
  });
}
