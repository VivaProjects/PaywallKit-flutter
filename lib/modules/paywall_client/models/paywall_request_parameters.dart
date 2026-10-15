import '../../web_paywall/models/web_paywall_environment.dart';
import 'paywall_configuration_request.dart';

/// GET 配置入口共用标准环境参数，附加路由参数不注入 H5。
class PaywallRequestParameters {
  PaywallRequestParameters(
      {required this.environment, Map<String, String> additional = const {}})
      : additional = Map.unmodifiable(additional);
  final WebPaywallEnvironment environment;
  final Map<String, String> additional;

  /// 稳定排序并编码查询参数，拒绝重复键和覆盖标准条件。
  PaywallConfigurationRequest request(Uri endpoint) {
    final values = environment.toPayload()..remove('placement');
    for (final entry in additional.entries) {
      if (entry.key.isEmpty || values.containsKey(entry.key))
        throw const FormatException('Reserved query parameter');
      values[entry.key] = entry.value;
    }
    for (final entry in endpoint.queryParametersAll.entries) {
      if (entry.key.isEmpty ||
          values.containsKey(entry.key) ||
          entry.value.length != 1)
        throw const FormatException('Duplicate query parameter');
      values[entry.key] = entry.value.single;
    }
    final keys = values.keys.toList()..sort();
    return PaywallConfigurationRequest(
        uri: endpoint.replace(
            queryParameters: {for (final key in keys) key: values[key]}),
        environment: environment);
  }
}
