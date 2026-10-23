import 'dart:convert';
import '../../paywall_renderer/models/paywall_catalog.dart';
import 'web_paywall_document.dart';
import 'web_paywall_session_policy.dart';

enum WebPaywallPresentation { fullScreen, halfSheet, halfSheetLocked, push }

/// 与 iOS 使用相同的配置快照，完整验证后才向点位入口开放。
class WebPaywallConfiguration {
  /// 查询转换与配置解析共用有界页面上限，支持多点位独立绑定。
  static const maxPages = 16;
  WebPaywallConfiguration._(this.placements, this.documents, this.presentations,
      this.sessions, this.disabledPlacements, this.preloadIds, this.source);
  final String source;
  final Map<String, String> placements;
  final Map<String, WebPaywallDocument> documents;
  final Map<String, WebPaywallPresentation> presentations;
  final Map<String, WebPaywallSessionPolicy> sessions;
  final Set<String> disabledPlacements;
  final List<String> preloadIds;

  /// 关闭的点位不允许被普通解析或回退重新打开。
  WebPaywallDocument? documentForPlacement(String placement) =>
      disabledPlacements.contains(placement)
          ? null
          : documents[placements[placement]];

  /// 校验页面、商品目录和点位之间的全部引用，禁止接受半份配置。
  static WebPaywallConfiguration parse(
    String source, {
    required Set<String>? allowedOrigins,
    required Map<String, PaywallCatalog> catalogs,
    String? developmentHTTPOrigin,
  }) {
    if (utf8.encode(source).length > 1000000)
      throw const FormatException('Configuration too large');
    final raw = jsonDecode(source) as Map<String, dynamic>;
    const keys = {
      'version',
      'placements',
      'paywalls',
      'presentations',
      'preload',
      'sessions',
      'sheetAspectRatios',
      'disabledPlacements'
    };
    if (raw['version'] != 1 || raw.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Invalid configuration');
    }
    final placements = Map<String, String>.from(raw['placements'] as Map);
    final documents = _documents(raw['paywalls'] as Map, catalogs,
        allowedOrigins, developmentHTTPOrigin);
    final preload = List<String>.from(raw['preload'] as List);
    final disabled =
        List<String>.from(raw['disabledPlacements'] as List? ?? []);
    if (placements.values.any((id) => !documents.containsKey(id)) ||
        preload.any((id) => !documents.containsKey(id)) ||
        preload.toSet().length != preload.length ||
        disabled.toSet().length != disabled.length) {
      throw const FormatException('Invalid placement references');
    }
    return _policies(raw, placements, documents, preload, disabled);
  }

  /// 每个页面独立核对注册目录和来源，再交给整份配置检查点位引用。
  static Map<String, WebPaywallDocument> _documents(
      Map payload,
      Map<String, PaywallCatalog> catalogs,
      Set<String>? allowedOrigins,
      String? developmentHTTPOrigin) {
    final payloads = Map<String, dynamic>.from(payload);
    if (payloads.length > maxPages)
      throw const FormatException('Too many pages');
    final documents = <String, WebPaywallDocument>{};
    for (final entry in payloads.entries) {
      final data = Map<String, dynamic>.from(entry.value as Map);
      final catalog = catalogs[data['catalogKey']];
      if (catalog == null || data['documentId'] != entry.key)
        throw const FormatException('Unknown page catalog');
      documents[entry.key] = WebPaywallDocument.parse(data,
          allowedOrigins: allowedOrigins,
          catalog: catalog,
          developmentHTTPOrigin: developmentHTTPOrigin);
    }
    return documents;
  }

  /// 缺失展示模式沿用全屏，未知模式和未知策略点位直接拒绝。
  static WebPaywallConfiguration _policies(
      Map<String, dynamic> raw,
      Map<String, String> placements,
      Map<String, WebPaywallDocument> documents,
      List<String> preload,
      List<String> disabled) {
    final modes = placements
        .map((key, _) => MapEntry(key, WebPaywallPresentation.fullScreen));
    final policies = <String, WebPaywallSessionPolicy>{};
    for (final entry in (raw['presentations'] as Map? ?? {}).entries) {
      if (!placements.containsKey(entry.key))
        throw const FormatException('Unknown presentation placement');
      modes[entry.key as String] =
          WebPaywallPresentation.values.byName(entry.value as String);
    }
    for (final entry in (raw['sessions'] as Map? ?? {}).entries) {
      final document = documents[placements[entry.key]];
      if (document == null)
        throw const FormatException('Unknown session placement');
      policies[entry.key as String] = WebPaywallSessionPolicy.parse(
          Map<String, dynamic>.from(entry.value as Map),
          document,
          placements.keys.toSet(),
          entry.key as String);
    }
    return WebPaywallConfiguration._(
        Map.unmodifiable(placements),
        Map.unmodifiable(documents),
        Map.unmodifiable(modes),
        Map.unmodifiable(policies),
        Set.unmodifiable(disabled),
        List.unmodifiable(preload),
        jsonEncode(raw));
  }
}
