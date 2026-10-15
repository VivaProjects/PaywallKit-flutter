import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../../web_paywall/models/web_paywall_session_policy.dart';

/// 解析后固定页面、入口和环境，展示期间不会被配置刷新替换。
class PaywallPlacement {
  const PaywallPlacement(
      {required this.name,
      required this.document,
      required this.environment,
      required this.presentation,
      this.sessionPolicy,
      this.requestIdentity,
      this.configurationSnapshot,
      this.clientIdentity,
      this.source = 'remote_or_cache',
      this.fallbackReason});
  final String? requestIdentity;
  final String? configurationSnapshot;
  final Object? clientIdentity;
  final String source;
  final String? fallbackReason;
  final String name;
  final WebPaywallDocument document;
  final WebPaywallEnvironment environment;
  final WebPaywallPresentation presentation;
  final WebPaywallSessionPolicy? sessionPolicy;
}
