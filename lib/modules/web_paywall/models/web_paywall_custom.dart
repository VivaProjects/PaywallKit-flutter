import 'dart:convert';

/// 冻结宿主传入的 JSON，避免预加载后外部修改影响会话内容。
Map<String, dynamic> freezeWebPaywallCustom(Map<String, dynamic> value) {
  final frozen = _freezeValue(value);
  return frozen as Map<String, dynamic>;
}

/// 只接受标准 JSON 类型，并在每一层保留不可修改的会话快照。
Object? _freezeValue(Object? value) {
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    if (!value.isFinite) {
      throw const FormatException('custom contains a non-finite number');
    }
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('custom contains a non-string key');
    }
    final result = <String, dynamic>{};
    for (final key in value.keys.cast<String>().toList()..sort()) {
      result[key] = _freezeValue(value[key]);
    }
    return Map<String, dynamic>.unmodifiable(result);
  }
  throw const FormatException('custom contains a non-JSON value');
}

/// 使用稳定的 JSON 表示比较预加载会话参数。
String webPaywallCustomIdentity(Map<String, dynamic> value) =>
    jsonEncode(value);
