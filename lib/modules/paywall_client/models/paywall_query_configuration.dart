import '../services/paywall_environment_provider.dart';
import 'paywall_configuration_request.dart';
import '../../web_paywall/services/web_paywall_package_loader.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_runtime_environment.dart';
import 'paywall_query_fallback.dart';
import 'paywall_query_update_diagnostic.dart';

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
      this.remoteUpdatesEnabled = false,
      this.developmentHTTPOrigin,
      this.waitUntilNetworkAvailable,
      this.waitUntilNetworkAvailableCancellable,
      this.fetch,
      this.onUpdateDiagnostic,
      this.packageLoader,
      this.legacyCacheNamespaces = const [],
      Stream<String>? storefrontChanges})
      : environment = environment == null
            ? (() => PaywallEnvironmentProvider.capture(
                runtimeEnvironment: runtimeEnvironment))
            : (() async => PaywallEnvironmentProvider.cacheEnvironment(
                await environment())),
        storefrontChanges =
            storefrontChanges ?? PaywallEnvironmentProvider.storefrontChanges,
        allowedOrigins =
            allowedOrigins == null ? null : Set.unmodifiable(allowedOrigins),
        placements = Map.unmodifiable(placements);

  /// 网络等待由宿主实现，取消信号在最后一个共享 Client 释放时完成。
  final Future<void> Function(Future<void> cancelled)?
      waitUntilNetworkAvailableCancellable;

  /// 兼容已有宿主；同时配置时优先使用可取消回调。
  final Future<void> Function()? waitUntilNetworkAvailable;
  final List<String> legacyCacheNamespaces;

  /// 共享运行时每次更新仅通知首个配置的监听者，日志关闭时保持静默。
  final void Function(PaywallQueryUpdateDiagnostic)? onUpdateDiagnostic;

  /// 可注入传输和完整包加载器，便于离线验证协议及启动缓存。
  final Future<String> Function(PaywallConfigurationRequest)? fetch;
  final WebPaywallPackageLoader? packageLoader;

  /// 默认关闭，仅使用完整缓存或内置包；宿主可调用 Client.enableRemoteUpdates() 开启。
  final bool remoteUpdatesEnabled;
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
