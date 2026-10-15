import '../services/paywall_environment_provider.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_runtime_environment.dart';
import 'paywall_query_fallback.dart';

/// 高层查询声明；运行环境由宿主显式选择，不从编译或商店沙盒推断。
class PaywallQueryConfiguration {
  PaywallQueryConfiguration(
      {required this.endpoint,
      required this.cacheNamespace,
      required Set<String>? allowedOrigins,
      required Map<String, String> placements,
      Future<WebPaywallEnvironment> Function()? environment,
      this.runtimeEnvironment = WebPaywallRuntimeEnvironment.test,
      this.fallback,
      this.developmentHTTPOrigin,
      Stream<String>? storefrontChanges})
      : environment = environment ??
            (() => PaywallEnvironmentProvider.capture(
                runtimeEnvironment: runtimeEnvironment)),
        storefrontChanges =
            storefrontChanges ?? PaywallEnvironmentProvider.storefrontChanges,
        allowedOrigins =
            allowedOrigins == null ? null : Set.unmodifiable(allowedOrigins),
        placements = Map.unmodifiable(placements);
  final Uri endpoint;
  final String cacheNamespace;
  final Set<String>? allowedOrigins;
  final Map<String, String> placements;
  final Future<WebPaywallEnvironment> Function() environment;
  final WebPaywallRuntimeEnvironment runtimeEnvironment;
  final PaywallQueryFallback? fallback;
  final String? developmentHTTPOrigin;
  final Stream<String>? storefrontChanges;
  String get cacheScope => '$cacheNamespace.${runtimeEnvironment.name}';
}
