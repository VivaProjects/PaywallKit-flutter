import 'dart:convert';
import 'dart:io';
import '../lib/modules/paywall_renderer/models/paywall_catalog.dart';
import '../lib/modules/paywall_renderer/models/paywall_snapshot.dart';
import '../lib/modules/paywall_renderer/services/paywall_signature_verifier.dart';

/// 跨端协议 CLI，不依赖 Flutter 引擎、模拟器或原生构建。
Future<void> main() async {
  final root = Directory.current.path;
  final schema =
      jsonDecode(File('$root/assets/paywall.schema.json').readAsStringSync());
  final catalog = jsonDecode(
      File('$root/assets/component-catalog.json').readAsStringSync());
  final source = File('$root/assets/onboarding.json').readAsStringSync();
  PaywallSnapshot parse(String value) =>
      PaywallSnapshot.validateTrusted(value, schema, catalog,
          placement: 'onboarding_complete',
          locale: 'zh-Hans-CN',
          storefrontGroup: 'test',
          catalogs: {
            'default': PaywallCatalog(
                productRefs: ['annual', 'monthly'], recommendedRef: 'annual')
          },
          assetIDs: {
            'movement_hero'
          });
  final snapshot = parse(source);
  if (snapshot.locale != 'zh-Hans' || snapshot.text('cta.continue') != '继续')
    throw StateError('locale fallback');
  final mutations = <String, void Function(Map)>{
    'unknown component': (d) => d['tree']['children'][2]['type'] = 'webView',
    'unknown field': (d) => d['tree']['children'][5]['props']['price'] = 0.01,
    'boolean version': (d) => d['revision'] = true,
    'unknown action': (d) =>
        d['bottomBar']['props']['action']['type'] = 'script',
    'duplicate identity': (d) => d['tree']['children'][0]['nodeId'] = 'root',
    'missing default': (d) => d['localization']['defaultLocale'] = 'missing',
    'missing translation': (d) =>
        d['localization']['locales']['en']['strings'].remove('title.main'),
    'future renderer': (d) => d['minimumRendererVersion']['flutter'] = 2,
    'missing CTA': (d) => d.remove('bottomBar'),
  };
  for (final entry in mutations.entries) {
    final bad = jsonDecode(source) as Map;
    entry.value(bad);
    try {
      parse(jsonEncode(bad));
    } on FormatException {
      stdout.writeln('PASS ${entry.key}');
      continue;
    }
    throw StateError('Accepted ${entry.key}');
  }
  final vectors =
      jsonDecode(File('$root/protocol/vectors.json').readAsStringSync());
  final verifier = PaywallSignatureVerifier(
      {'contract-test': base64Decode(vectors['publicKey'])});
  final envelope = utf8.encode(jsonEncode(vectors['envelope']));
  final payload = await verifier.payload(envelope);
  if (utf8.decode(payload) != vectors['payload'])
    throw StateError('signature payload');
  final tampered = Map<String, dynamic>.from(vectors['envelope']);
  tampered['payload'] = base64Encode([...payload, 32]);
  var rejected = false;
  try {
    await verifier.payload(utf8.encode(jsonEncode(tampered)));
  } on FormatException {
    rejected = true;
  }
  if (!rejected) throw StateError('tampered payload accepted');
  for (final vector in vectors['buckets']) {
    if (verifier.bucket(vector['installationId'], vector['experimentId']) !=
        vector['bucket']) throw StateError('bucket mismatch');
  }
  stdout.writeln(
      'PASS locale fallback, signature interoperability, tamper rejection and 4 stable bucket vectors');
}
