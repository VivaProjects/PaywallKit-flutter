import 'web_paywall_custom.dart';
import 'web_paywall_document.dart';

/// 宿主配置决定可购买商品、可缺失商品和后续点位，H5 不决定交易权限。
class WebPaywallSessionPolicy {
  WebPaywallSessionPolicy._(this.purchasableProductRefs,
      this.optionalProductRefs, this.custom, this.nextPlacement);
  final List<String> purchasableProductRefs;
  final List<String> optionalProductRefs;
  final Map<String, dynamic> custom;
  final String? nextPlacement;

  /// 按已校验页面绑定验证策略，展示用的对比商品不能被购买。
  static WebPaywallSessionPolicy parse(Map<String, dynamic> raw,
      WebPaywallDocument document, Set<String> placements, String placement) {
    const keys = {
      'purchasableProductRefs',
      'optionalProductRefs',
      'custom',
      'nextPlacement'
    };
    final purchases = raw['purchasableProductRefs'];
    final optional = raw['optionalProductRefs'];
    final custom = raw['custom'];
    final next = raw['nextPlacement'];
    if (raw.keys.any((key) => !keys.contains(key)) ||
        !_validRefs(purchases, document) ||
        !(purchases as List).contains(document.initialProductRef) ||
        !_validRefs(optional, document) ||
        (optional as List).any(purchases.contains) ||
        custom is! Map<String, dynamic> ||
        custom.length > 16 ||
        custom.entries.any((entry) =>
            entry.key.isEmpty ||
            entry.key.length > 64 ||
            entry.value is! String ||
            (entry.value as String).length > 256) ||
        (next != null &&
            (next is! String ||
                next == placement ||
                !placements.contains(next)))) {
      throw const FormatException('Invalid session policy');
    }
    return WebPaywallSessionPolicy._(
        List<String>.unmodifiable(purchases),
        List<String>.unmodifiable(optional),
        freezeWebPaywallCustom(custom),
        next as String?);
  }

  /// 策略引用不能越过页面商品目录或重复声明。
  static bool _validRefs(Object? value, WebPaywallDocument document) =>
      value is List &&
      value.toSet().length == value.length &&
      value.every((ref) => ref is String && document.productRefs.contains(ref));
}
