import 'web_paywall_runtime_environment.dart';

/// 宿主提供的 H5 适配环境；设备型号不应包含唯一设备标识。
class WebPaywallEnvironment {
  const WebPaywallEnvironment({
    this.placement = '',
    this.runtimeEnvironment = WebPaywallRuntimeEnvironment.test,
    required this.language,
    required this.deviceModel,
    required this.country,
    required this.appVersion,
  });

  final String placement;
  final WebPaywallRuntimeEnvironment runtimeEnvironment;
  final String language;
  final String deviceModel;
  final String country;
  final String appVersion;

  /// 仅将标准环境信息写入桥协议，不附带宿主页面文案。
  Map<String, String> toPayload() => {
        'placement': placement,
        'runtimeEnvironment': runtimeEnvironment.name,
        'language': language,
        'deviceModel': deviceModel,
        'country': country,
        'appVersion': appVersion,
      };
}
