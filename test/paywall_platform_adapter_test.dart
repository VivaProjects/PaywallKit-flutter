import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('native_paywall/resources');
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test(
      'platform adapter keeps store country and product disclosures without injecting copy',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'resolveCountry') {
        return (call.arguments as Map)['country'];
      }
      if (call.method == 'environment')
        return {
          'os': 'iOS',
          'isPad': true,
          'language': 'en-US',
          'country': 'CAN',
          'deviceModel': 'model',
          'appVersion': '1.2'
        };
      expect(call.method, 'storeProducts');
      expect((call.arguments as Map)['productRefs'], ['annual']);
      return [
        {
          'productRef': 'annual',
          'storeProductId': 'annual',
          'title': 'Store title',
          'displayPrice': r'CA$9.99',
          'disclosure': 'renews monthly',
          'periodText': '1 month',
          'isEligibleForFreeTrial': false,
          'subscriptionPricing': {
            'phases': [
              {
                'priceAmount': '9.99',
                'currencyCode': 'CAD',
                'displayPrice': r'CA$9.99',
                'billingPeriod': 'P1M',
                'billingCycleCount': 0,
                'recurrenceMode': 'infiniteRecurring',
              }
            ]
          }
        }
      ];
    });
    final env = await PaywallEnvironmentProvider.capture(
        runtimeEnvironment: WebPaywallRuntimeEnvironment.production);
    expect(env.country, 'CAN');
    expect(env.os, 'iOS');
    expect(env.isPad, isTrue);
    expect(env.runtimeEnvironment, WebPaywallRuntimeEnvironment.production);
    final products = await PaywallStoreKitProductMapper.products(['annual']);
    expect(products.single.displayPrice, r'CA$9.99');
    expect(products.single.isEligibleForFreeTrial, isFalse);
    expect(
        products.single.subscriptionPricing!.phases.single.currencyCode, 'CAD');
    expect(
        (await PaywallEnvironmentProvider.capture(
                storefrontCountry: () async => 'USA'))
            .country,
        'USA');
  });

  test(
      'country failure reuses last success without retry or environment mixing',
      () async {
    final countries = <String, String>{};
    var queries = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'environment') {
        return {
          'os': 'Android',
          'isPad': false,
          'country': '',
          'language': 'en',
          'deviceModel': 'model',
          'appVersion': '1'
        };
      }
      if (call.method == 'resolveCountry') {
        final args = call.arguments as Map;
        final scope = args['runtimeEnvironment'] as String;
        final country = args['country'] as String;
        if (country.isNotEmpty) countries[scope] = country;
        return countries[scope] ?? '';
      }
      throw MissingPluginException();
    });
    Future<WebPaywallEnvironment> capture(String? result,
            {WebPaywallRuntimeEnvironment environment =
                WebPaywallRuntimeEnvironment.test}) =>
        PaywallEnvironmentProvider.capture(
            runtimeEnvironment: environment,
            storefrontCountry: () async {
              queries++;
              if (result == null) throw StateError('store unavailable');
              return result;
            });

    expect((await capture('')).country, '');
    expect((await capture('usa')).country, 'USA');
    expect((await capture(null)).country, 'USA');
    expect((await capture('')).country, 'USA');
    expect(
        (await capture('',
                environment: WebPaywallRuntimeEnvironment.production))
            .country,
        '');
    expect((await capture('CAN')).country, 'CAN');
    expect((await capture(null)).country, 'CAN');
    expect(queries, 7);
  });

  test(
      'device parameters retain types across query, placement and cache identity',
      () {
    WebPaywallEnvironment device(String os, bool isPad) =>
        WebPaywallEnvironment(
            os: os,
            isPad: isPad,
            language: 'en',
            deviceModel: 'model',
            country: 'USA',
            appVersion: '1');
    PaywallConfigurationRequest query(WebPaywallEnvironment env) =>
        PaywallConfigurationRequest.query(
            endpoint: Uri.parse('https://example.com/query'),
            environment: env,
            channelKey: 'organic');
    final tablet = device('Android', true);
    final request = query(tablet);
    final conditions = (jsonDecode(request.body!) as Map)['conditions'] as Map;
    expect(conditions['os'], 'Android');
    expect(conditions['isPad'], isTrue);
    expect(tablet.forPlacement('banner').toPayload()['isPad'], isTrue);
    expect(tablet.forPlacement('banner').os, 'Android');
    expect(request.identity('app'),
        isNot(query(device('Android', false)).identity('app')));
    expect(request.identity('app'),
        isNot(query(device('iOS', true)).identity('app')));
    final get = PaywallRequestParameters(environment: tablet)
        .request(Uri.parse('https://example.com/config'));
    expect(get.uri.queryParameters['os'], 'Android');
    expect(get.uri.queryParameters['isPad'], 'true');
    expect(() => device('android', false).toPayload(), throwsFormatException);
  });

  test(
      'GET parameters sort and preserve literal plus while refusing duplicate and reserved fields',
      () {
    const env = WebPaywallEnvironment(
        os: 'iOS',
        language: 'en',
        deviceModel: 'phone',
        country: 'USA',
        appVersion: '1');
    final parameters = PaywallRequestParameters(
        environment: env, additional: {'channel': 'a+b'});
    final request =
        parameters.request(Uri.parse('https://example.com/config?fixed=1'));
    expect(request.uri.queryParameters['channel'], 'a+b');
    expect(request.uri.query, contains('a%2Bb'));
    expect(request.uri.queryParameters.containsKey('placement'), isFalse);
    expect(
        () => parameters
            .request(Uri.parse('https://example.com/config?fixed=1&fixed=2')),
        throwsFormatException);
    expect(
        () => PaywallRequestParameters(
                environment: env, additional: {'country': 'CAN'})
            .request(Uri.parse('https://example.com/config')),
        throwsFormatException);
  });
}
