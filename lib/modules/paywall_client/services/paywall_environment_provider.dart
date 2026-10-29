import 'dart:io';
import 'package:flutter/services.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_runtime_environment.dart';

/// 平台默认适配信息；Android 商店国家可由宿主现有 Billing 服务覆盖。
class PaywallEnvironmentProvider {
  /// iOS 自动读取 StoreKit 国家，Android 使用宿主商店查询；查询为空或失败时读取最近成功国家。
  static Future<WebPaywallEnvironment> capture(
      {WebPaywallRuntimeEnvironment runtimeEnvironment =
          WebPaywallRuntimeEnvironment.test,
      Future<String> Function()? storefrontCountry}) async {
    final values = await const MethodChannel('native_paywall/resources')
        .invokeMapMethod<String, Object>('environment');
    // 宿主商店查询失败只降级国家，不丢弃已采集的设备环境。
    var country = values?['country'] as String? ?? '';
    if (storefrontCountry != null) {
      try {
        country = await storefrontCountry();
      } catch (_) {
        country = '';
      }
    }
    country = await resolveCountry(country, runtimeEnvironment);
    return WebPaywallEnvironment(
        os: values?['os'] as String?,
        isPad: values?['isPad'] as bool? ?? false,
        runtimeEnvironment: runtimeEnvironment,
        language: values?['language'] as String? ?? '',
        deviceModel: values?['deviceModel'] as String? ?? '',
        appVersion: values?['appVersion'] as String? ?? '',
        country: country);
  }

  /// 高层自定义环境同样更新国家缓存，并保留会话适配字段。
  static Future<WebPaywallEnvironment> cacheEnvironment(
      WebPaywallEnvironment environment) async {
    final country = await resolveCountry(
        environment.country, environment.runtimeEnvironment);
    return WebPaywallEnvironment(
        os: environment.os,
        isPad: environment.isPad,
        waitsForProducts: environment.waitsForProducts,
        placement: environment.placement,
        runtimeEnvironment: environment.runtimeEnvironment,
        language: environment.language,
        deviceModel: environment.deviceModel,
        country: country,
        appVersion: environment.appVersion);
  }

  /// 成功值持久缓存；空结果使用缓存，不重试、不增加等待窗口。
  static Future<String> resolveCountry(
      String country, WebPaywallRuntimeEnvironment runtimeEnvironment) async {
    final value = country.toUpperCase();
    // 非空错误配置仍按既有协议报错，不能静默保存为成功国家。
    if (value.isNotEmpty && !RegExp(r'^[A-Z]{3}$').hasMatch(value)) {
      throw const FormatException('Country must be a store alpha-3 code');
    }
    try {
      return await const MethodChannel('native_paywall/resources')
              .invokeMethod<String>('resolveCountry', {
            'country': value,
            'runtimeEnvironment': runtimeEnvironment.name,
          }) ??
          value;
    } on PlatformException {
      // 本地持久化不可用时，真实查询结果仍可用于展示。
      return value;
    } on MissingPluginException {
      return value;
    }
  }

  /// iOS 订阅真实商店变更；Android 保持宿主注入流，不推断商店账户。
  static Stream<String>? get storefrontChanges => Platform.isIOS
      ? const EventChannel('native_paywall/storefront')
          .receiveBroadcastStream()
          .where((value) => value is String)
          .cast<String>()
      : null;
}
