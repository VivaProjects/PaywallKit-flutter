import 'dart:convert';
import '../services/schema_validator.dart';
import 'paywall_catalog.dart';
import 'paywall_node.dart';

/// 页面冻结后的值对象；集合全部不可修改。
class PaywallSnapshot {
  PaywallSnapshot._(
      Map<String, dynamic> doc,
      String requestedLocale,
      this.storefrontGroup,
      PaywallCatalog catalog,
      Map<String, String> assignment)
      : assignment = Map.unmodifiable(assignment),
        documentId = doc['documentId'],
        revision = doc['revision'],
        placement = doc['placement'],
        variant = doc['tracking']['variant'],
        productRefs = List.unmodifiable(catalog.productRefs),
        recommendedRef = catalog.recommendedRef,
        nodes = List.unmodifiable((doc['tree']['children'] as List)
            .map((v) => PaywallNode.fromValidated(v))),
        bottomBar = PaywallNode.fromValidated(doc['bottomBar']),
        accent = doc['tokens']['color']['accent'],
        cardRadius = doc['tokens']['shape']['card'] == 'radius26' ? 26 : 16,
        spacing =
            Map.unmodifiable(Map<String, num>.from(doc['tokens']['spacing'])) {
    final locales = doc['localization']['locales'] as Map;
    final fallback = doc['localization']['defaultLocale'] as String;
    final chain = _localeChain(requestedLocale, fallback);
    locale = chain.firstWhere(locales.containsKey);
    final texts = <String, String>{};
    final items = <String, List<String>>{};
    for (final key in chain.reversed) {
      final language = locales[key];
      if (language == null) continue;
      texts.addAll(Map<String, String>.from(language['strings']));
      for (final entry in (language['lists'] as Map).entries) {
        items[entry.key] = List<String>.unmodifiable(entry.value);
      }
    }
    strings = Map.unmodifiable(texts);
    lists = Map.unmodifiable(items);
  }

  final Map<String, String> assignment;
  final String documentId,
      placement,
      variant,
      storefrontGroup,
      recommendedRef,
      accent;
  final int revision;
  final double cardRadius;
  final List<String> productRefs;
  final List<PaywallNode> nodes;
  final PaywallNode bottomBar;
  final Map<String, num> spacing;
  late final String locale;
  late final Map<String, String> strings;
  late final Map<String, List<String>> lists;

  /// 此入口仅供经过信任校验的包内或签名数据；SDK 服务负责信任来源。
  static PaywallSnapshot validateTrusted(String source,
      Map<String, dynamic> schema, Map<String, dynamic> components,
      {required String placement,
      required String locale,
      required String storefrontGroup,
      required Map<String, PaywallCatalog> catalogs,
      required Set<String> assetIDs,
      Map<String, String> assignment = const {}}) {
    if (utf8.encode(source).length > 262144)
      throw const FormatException('byte_limit');
    final doc = jsonDecode(source);
    SchemaValidator(schema).validate(doc);
    if (doc['placement'] != placement ||
        doc['minimumRendererVersion']['flutter'] > 1) {
      throw const FormatException(r'$.placement: incompatible_context');
    }
    final nodes = [doc['tree'], ...doc['tree']['children'], doc['bottomBar']];
    _validateIdentity(doc, nodes, components);
    _validateContent(doc, nodes, assetIDs);
    final pickers = nodes.where((v) => v['type'] == 'productPicker').toList();
    if (pickers.length != 1 ||
        nodes.where((v) => v['type'] == 'legalActions').length != 1 ||
        nodes.where((v) => v['type'] == 'closeButton').length > 1) {
      throw const FormatException(r'$.tree: purchase_contract');
    }
    final catalog = catalogs[pickers.single['props']['catalogKey']];
    if (catalog == null ||
        catalog.productRefs.isEmpty ||
        catalog.productRefs.length > 12 ||
        catalog.productRefs.any((v) => v.isEmpty) ||
        catalog.productRefs.toSet().length != catalog.productRefs.length ||
        !catalog.productRefs.contains(catalog.recommendedRef)) {
      throw const FormatException(r'$.tree: invalid_catalog');
    }
    return PaywallSnapshot._(doc, locale, storefrontGroup, catalog, assignment);
  }

  /// 节点身份与能力必须同时满足，未知能力禁止降级成局部空白。
  static void _validateIdentity(Map doc, List nodes, Map components) {
    if (nodes.length > 80 ||
        nodes.map((v) => v['nodeId']).toSet().length != nodes.length) {
      throw const FormatException(r'$.tree: duplicate_id_or_node_limit');
    }
    final mapping = {
      for (final c in components['components']) c['type']: c['capability']
    };
    final declared = Set<String>.from(doc['requiredCapabilities']);
    if (!declared.every(mapping.values.contains) ||
        !nodes.every((v) => declared.contains(mapping[v['type']]))) {
      throw const FormatException(
          r'$.requiredCapabilities: unsupported_or_missing_capability');
    }
  }

  /// 默认语言负责完整性；所有资源引用必须已在客户端注册。
  static void _validateContent(Map doc, List nodes, Set<String> assetIDs) {
    final base =
        doc['localization']['locales'][doc['localization']['defaultLocale']];
    if (base == null)
      throw const FormatException(r'$.localization: missing_default');
    for (final node in nodes) {
      final props = node['props'] as Map;
      for (final field in [
        'textKey',
        'altKey',
        'titleKey',
        'bodyKey',
        'labelKey'
      ]) {
        if (props[field] != null && base['strings'][props[field]] == null) {
          throw FormatException(
              'node ${node['nodeId']}: missing_text ${props[field]}');
        }
      }
      if (props['itemsKey'] != null &&
          base['lists'][props['itemsKey']] == null) {
        throw FormatException('node ${node['nodeId']}: missing_list');
      }
      if (props['assetId'] != null && !assetIDs.contains(props['assetId'])) {
        throw FormatException('node ${node['nodeId']}: unknown_asset');
      }
    }
  }

  /// 与 iOS 使用相同的语言截断与默认回退规则。
  static List<String> _localeChain(String locale, String fallback) {
    final parts = locale.replaceAll('_', '-').split('-');
    final result = <String>[];
    while (parts.isNotEmpty) {
      result.add(parts.join('-'));
      parts.removeLast();
    }
    if (!result.contains(fallback)) result.add(fallback);
    return result;
  }

  String text(String? key) => strings[key] ?? '';
}
