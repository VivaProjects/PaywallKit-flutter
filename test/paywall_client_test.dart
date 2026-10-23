import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_paywall/native_paywall.dart';
import 'package:native_paywall/modules/web_paywall/models/web_paywall_custom.dart';

const environment = WebPaywallEnvironment(
    os: 'iOS',
    language: 'en',
    deviceModel: 'phone',
    country: 'usa',
    appVersion: '1');
final catalog = PaywallCatalog(
    productRefs: ['annual', 'compare'], recommendedRef: 'annual');
Map<String, dynamic> payload({bool disabled = false}) => {
      'version': 1,
      'placements': {'settings': 'page'},
      'preload': ['page'],
      'disabledPlacements': disabled ? ['settings'] : [],
      'presentations': {'settings': 'halfSheetLocked'},
      'sessions': {
        'settings': {
          'purchasableProductRefs': ['annual'],
          'optionalProductRefs': ['compare'],
          'custom': {'flow': 'settings'}
        }
      },
      'paywalls': {
        'page': {
          'kind': 'web-paywall',
          'bridgeVersion': 2,
          'documentId': 'page',
          'revision': 1,
          'pageUrl': 'https://example.com/v1/index.html',
          'catalogKey': 'default',
          'productRefs': ['annual', 'compare'],
          'initialProductRef': 'annual'
        }
      }
    };
WebPaywallConfiguration parse(Map<String, dynamic> value) =>
    WebPaywallConfiguration.parse(jsonEncode(value),
        allowedOrigins: {'https://example.com'},
        catalogs: {'default': catalog});
PaywallConfigurationRequest request(
        [String channel = 'organic',
        WebPaywallEnvironment env = environment]) =>
    PaywallConfigurationRequest.query(
        endpoint: Uri.parse('https://example.com/query'),
        environment: env,
        channelKey: channel);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('paywall-config-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
      'configuration freezes placement bindings and disabled placements cannot resolve',
      () {
    final raw = payload();
    final config = parse(raw);
    raw['placements']['settings'] = 'another';
    expect(config.documentForPlacement('settings')!.documentId, 'page');
    expect(config.presentations['settings'],
        WebPaywallPresentation.halfSheetLocked);
    expect(config.sessions['settings']!.purchasableProductRefs, ['annual']);
    expect(parse(payload(disabled: true)).documentForPlacement('settings'),
        isNull);
    expect(() => config.placements['x'] = 'page', throwsUnsupportedError);
  });

  test(
      'invalid policy references, overlapping optional items and reserved custom fail closed',
      () {
    for (final patch in [
      {
        'purchasableProductRefs': ['missing']
      },
      {
        'optionalProductRefs': ['annual']
      },
      {'nextPlacement': 'settings'},
      {
        'custom': {'price': 'free'}
      },
      {
        'custom': {'runtimeEnvironment': 'production'}
      },
    ]) {
      final raw = payload();
      (raw['sessions']['settings'] as Map).addAll(patch);
      expect(() => parse(raw), throwsA(anything));
    }
    expect(
        () => freezeWebPaywallCustom({'content': {}}), throwsFormatException);
  });

  test('country normalization and POST body/environment identity are explicit',
      () {
    expect(environment.toPayload()['country'], 'USA');
    expect(jsonDecode(request().body!)['conditions']['country'], 'USA');
    expect(request('a').identity('app'), isNot(request('b').identity('app')));
    const production = WebPaywallEnvironment(
        os: 'iOS',
        language: 'en',
        deviceModel: 'phone',
        country: 'USA',
        appVersion: '1',
        runtimeEnvironment: WebPaywallRuntimeEnvironment.production);
    expect(request().identity('app'),
        isNot(request('organic', production).identity('app')));
    expect(() => request(''), throwsFormatException);
    expect(
        () => const WebPaywallEnvironment(
                os: 'iOS',
                language: 'en',
                deviceModel: 'phone',
                country: 'US',
                appVersion: '1')
            .toPayload(),
        throwsFormatException);
  });

  test('same request is deduplicated and real placement injected', () async {
    var calls = 0;
    final response = Completer<String>();
    final source = PaywallConfigurationSource(
        cacheNamespace: 'test',
        allowedOrigins: {'https://example.com'},
        catalogs: () => {'default': catalog},
        request: () async => request(),
        directory: () async => directory,
        fetch: (_) {
          calls++;
          return response.future;
        });
    final client = PaywallClient(configuration: source);
    final first = client.resolve('settings');
    final second = client.resolve('settings');
    response.complete(jsonEncode(payload()));
    final values = await Future.wait([first, second]);
    expect(calls, 1);
    expect(values.first!.environment.placement, 'settings');
    expect(values.last!.document.productRefs, ['annual', 'compare']);
    client.dispose();
  });

  test('offline cache is revalidated and never reused across POST conditions',
      () async {
    var online = true;
    var channel = 'one';
    final source = PaywallConfigurationSource(
        cacheNamespace: 'test',
        allowedOrigins: {'https://example.com'},
        catalogs: () => {'default': catalog},
        request: () async => request(channel),
        directory: () async => directory,
        fetch: (_) async {
          if (!online) throw const SocketException('offline');
          return jsonEncode(payload());
        });
    final client = PaywallClient(configuration: source);
    await client.refresh();
    online = false;
    expect(
        (await client.refresh()).documentForPlacement('settings'), isNotNull);
    channel = 'two';
    await expectLater(client.refresh(), throwsA(anything));
  });

  test(
      'invalidated response cannot write disk or overwrite newer configuration',
      () async {
    final oldResponse = Completer<String>();
    var calls = 0;
    final source = PaywallConfigurationSource(
        cacheNamespace: 'test',
        allowedOrigins: {'https://example.com'},
        catalogs: () => {'default': catalog},
        request: () async => request(),
        directory: () async => directory,
        fetch: (_) {
          calls++;
          return calls == 1
              ? oldResponse.future
              : Future.value(jsonEncode(payload(disabled: true)));
        });
    final client = PaywallClient(configuration: source);
    final old = client.refresh();
    final oldCheck = expectLater(old, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    client.invalidate();
    await client.refresh();
    oldResponse.complete(jsonEncode(payload()));
    await oldCheck;
    await expectLater(
        client.resolve('settings'), throwsA(PaywallFailure.disabled));
    final files =
        await Directory('${directory.path}/configuration').list().toList();
    expect(files.whereType<File>().length, 1);
    expect(
        jsonDecode(await files.whereType<File>().single.readAsString())[
            'disabledPlacements'],
        ['settings']);
  });
}
