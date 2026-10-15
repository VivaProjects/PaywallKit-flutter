import 'dart:io';
import 'package:flutter/services.dart';
import '../../web_paywall/models/web_paywall_environment.dart';
import '../../web_paywall/models/web_paywall_runtime_environment.dart';

/// 平台默认适配信息；Android 商店国家可由宿主现有 Billing 服务覆盖。
class PaywallEnvironmentProvider {
  /// iOS 自动读取 StoreKit 国家，Android 未提供商店国家时保持未知。
  static Future<WebPaywallEnvironment> capture(
      {WebPaywallRuntimeEnvironment runtimeEnvironment =
          WebPaywallRuntimeEnvironment.test,
      Future<String> Function()? storefrontCountry}) async {
    final values = await const MethodChannel('native_paywall/resources')
        .invokeMapMethod<String, String>('environment');
    final country = storefrontCountry != null
        ? await storefrontCountry()
        : values?['country'] ?? '';
    return WebPaywallEnvironment(
        runtimeEnvironment: runtimeEnvironment,
        language: values?['language'] ?? '',
        deviceModel: values?['deviceModel'] ?? '',
        appVersion: values?['appVersion'] ?? '',
        country: country);
  }

  /// iOS 订阅真实商店变更；Android 保持宿主注入流，不推断商店账户。
  static Stream<String>? get storefrontChanges => Platform.isIOS
      ? const EventChannel('native_paywall/storefront')
          .receiveBroadcastStream()
          .where((value) => value is String)
          .cast<String>()
      : null;
}
