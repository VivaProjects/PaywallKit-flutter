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
      if (call.method == 'environment')
        return {
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
          'isEligibleForFreeTrial': false
        }
      ];
    });
    final env = await PaywallEnvironmentProvider.capture(
        runtimeEnvironment: WebPaywallRuntimeEnvironment.production);
    expect(env.country, 'CAN');
    expect(env.runtimeEnvironment, WebPaywallRuntimeEnvironment.production);
    final products = await PaywallStoreKitProductMapper.products(['annual']);
    expect(products.single.displayPrice, r'CA$9.99');
    expect(products.single.isEligibleForFreeTrial, isFalse);
    expect(
        (await PaywallEnvironmentProvider.capture(
                storefrontCountry: () async => 'USA'))
            .country,
        'USA');
  });

  test(
      'GET parameters sort and preserve literal plus while refusing duplicate and reserved fields',
      () {
    const env = WebPaywallEnvironment(
        language: 'en', deviceModel: 'phone', country: 'USA', appVersion: '1');
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
