import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../web_paywall/models/web_paywall_environment.dart';

/// 请求快照同时用于网络和缓存身份，POST 条件不会共用 URL 缓存。
class PaywallConfigurationRequest {
  PaywallConfigurationRequest(
      {required this.uri,
      required this.environment,
      this.method = 'GET',
      this.body});
  final Uri uri;
  final WebPaywallEnvironment environment;
  final String method;
  final String? body;

  /// 查询协议保持 iOS 字段命名，归因值由宿主确认后再传入。
  factory PaywallConfigurationRequest.query(
      {required Uri endpoint,
      required WebPaywallEnvironment environment,
      required String channelKey}) {
    if (channelKey.trim().isEmpty)
      throw const FormatException('Attribution is pending');
    return PaywallConfigurationRequest(
        uri: endpoint,
        environment: environment,
        method: 'POST',
        body: jsonEncode({
          'conditions': {
            'os': environment.os,
            'isPad': environment.isPad,
            'channel': channelKey,
            'version': environment.appVersion,
            'device_type': environment.deviceModel,
            'language': environment.language,
            'country': environment.validatedCountry
          }
        }));
  }

  /// 完整请求与显式环境参与身份，配置变化后不能借用旧副本。
  String identity(String namespace) => sha256
      .convert(utf8.encode(jsonEncode([
        namespace,
        environment.toPayload()..remove('placement'),
        method,
        uri.toString(),
        body
      ])))
      .toString();
}
