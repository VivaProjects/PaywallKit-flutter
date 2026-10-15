enum PaywallNodeType {
  paywallScreen,
  hero,
  heading,
  benefitList,
  productPicker,
  informationSection,
  legalActions,
  spacer,
  purchaseBar,
  closeButton,
}

/// 仅在 Schema 与业务规则通过后转换，渲染层不读取未验证字典。
class PaywallNode {
  PaywallNode.fromValidated(Map<String, dynamic> json)
      : type = PaywallNodeType.values.byName(json['type']),
        nodeId = json['nodeId'],
        assetId = json['props']['assetId'],
        altKey = json['props']['altKey'],
        aspectRatio = (json['props']['aspectRatio'] as num?)?.toDouble() ?? 1.8,
        textKey = json['props']['textKey'],
        typography = json['props']['typography'],
        alignment = json['props']['alignment'],
        itemsKey = json['props']['itemsKey'],
        catalogKey = json['props']['catalogKey'],
        selection = json['props']['selection'],
        titleKey = json['props']['titleKey'],
        bodyKey = json['props']['bodyKey'],
        collapsible = json['props']['collapsible'] ?? false,
        spacingToken = json['props']['spacingToken'],
        labelKey = json['props']['labelKey'];

  final PaywallNodeType type;
  final String nodeId;
  final String? assetId, altKey, textKey, typography, alignment, itemsKey;
  final String? catalogKey,
      selection,
      titleKey,
      bodyKey,
      spacingToken,
      labelKey;
  final double aspectRatio;
  final bool collapsible;
}
