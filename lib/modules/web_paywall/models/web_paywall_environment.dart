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

  /// 高层入口冻结实际点位，不从页面 ID 推断入口。
  WebPaywallEnvironment forPlacement(String value) => WebPaywallEnvironment(
      placement: value,
      runtimeEnvironment: runtimeEnvironment,
      language: language,
      deviceModel: deviceModel,
      country: country,
      appVersion: appVersion);

  /// 国家只接受宿主从商店取得的 alpha-3 值，未知时保留空字符串。
  String get validatedCountry {
    final value = country.toUpperCase();
    if (value.isNotEmpty && !RegExp(r'^[A-Z]{3}$').hasMatch(value)) {
      throw const FormatException('Country must be a store alpha-3 code');
    }
    return value;
  }

  /// 仅将标准环境信息写入桥协议，不附带宿主页面文案。
  Map<String, String> toPayload() => {
        'placement': placement,
        'runtimeEnvironment': runtimeEnvironment.name,
        'language': language,
        'deviceModel': deviceModel,
        'country': validatedCountry,
        'appVersion': appVersion,
      };
}
