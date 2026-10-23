import '../lib/modules/paywall_renderer/models/paywall_catalog.dart';
import '../lib/modules/web_paywall/models/web_paywall_document.dart';
import '../lib/modules/web_paywall/models/web_paywall_environment.dart';
import '../lib/modules/web_paywall/models/web_paywall_runtime_environment.dart';
import '../lib/modules/web_paywall/models/web_paywall_session_identity.dart';

/// 不启动 Flutter 引擎，验证环境注入和实际预加载身份函数。
void main() {
  const test = WebPaywallEnvironment(
      os: 'iOS',
      language: 'en',
      deviceModel: 'phone',
      country: 'USA',
      appVersion: '1');
  const production = WebPaywallEnvironment(
      os: 'iOS',
      language: 'en',
      deviceModel: 'phone',
      country: 'USA',
      appVersion: '1',
      runtimeEnvironment: WebPaywallRuntimeEnvironment.production);
  const banner = WebPaywallEnvironment(
      os: 'iOS',
      language: 'en',
      deviceModel: 'phone',
      country: 'USA',
      appVersion: '1',
      placement: 'banner');
  const unlock = WebPaywallEnvironment(
      os: 'iOS',
      language: 'en',
      deviceModel: 'phone',
      country: 'USA',
      appVersion: '1',
      placement: 'unlock');
  final document = WebPaywallDocument.parse({
    'kind': 'web-paywall',
    'bridgeVersion': 2,
    'revision': 1,
    'documentId': 'page',
    'pageUrl': 'https://example.com/index.html',
    'catalogKey': 'default',
    'productRefs': ['annual'],
    'initialProductRef': 'annual',
  },
      allowedOrigins: {
        'https://example.com'
      },
      catalog:
          PaywallCatalog(productRefs: ['annual'], recommendedRef: 'annual'));
  String identity(WebPaywallEnvironment environment) =>
      webPaywallSessionIdentity(
          document: document,
          storefrontGroup: 'default',
          environment: environment,
          customIdentity: '{}');
  if (test.toPayload()['placement'] != '' ||
      banner.toPayload()['placement'] != 'banner' ||
      identity(banner) == identity(unlock) ||
      test.toPayload()['runtimeEnvironment'] != 'test' ||
      production.toPayload()['runtimeEnvironment'] != 'production' ||
      identity(test) == identity(production) ||
      identity(test) != identity(test)) {
    throw StateError('Environment payload or cache isolation failed');
  }
  print(
      'PASS default test, explicit production, stable and isolated session identity');
}
