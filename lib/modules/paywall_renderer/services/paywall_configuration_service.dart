import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/paywall_catalog.dart';
import '../models/paywall_snapshot.dart';

class PaywallConfigurationService {
  /// 默认示例或宿主预打包文档必须再次通过结构与业务校验。
  Future<PaywallSnapshot> loadBundled(
      {String asset = 'packages/native_paywall/assets/onboarding.json',
      required String placement,
      required String locale,
      required String storefrontGroup,
      required Map<String, PaywallCatalog> catalogs,
      required Set<String> assetIDs}) async {
    final data = await rootBundle.load(asset);
    if (data.lengthInBytes > 262144) throw const FormatException('byte_limit');
    return decodeDocument(
        utf8.decode(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
        placement: placement,
        locale: locale,
        storefrontGroup: storefrontGroup,
        catalogs: catalogs,
        assetIDs: assetIDs);
  }

  /// 接收宿主取得的 JSON，分发接口与来源验证由宿主负责。
  Future<PaywallSnapshot> decodeDocument(String source,
      {required String placement,
      required String locale,
      required String storefrontGroup,
      required Map<String, PaywallCatalog> catalogs,
      required Set<String> assetIDs}) async {
    // 固定包内规则保证所有来源的文档都经过相同检查。
    if (utf8.encode(source).length > 262144)
      throw const FormatException('byte_limit');
    final schema = await rootBundle
        .loadString('packages/native_paywall/assets/paywall.schema.json');
    final catalog = await rootBundle
        .loadString('packages/native_paywall/assets/component-catalog.json');
    return PaywallSnapshot.validateTrusted(
        source, jsonDecode(schema), jsonDecode(catalog),
        placement: placement,
        locale: locale,
        storefrontGroup: storefrontGroup,
        catalogs: catalogs,
        assetIDs: assetIDs);
  }
}
