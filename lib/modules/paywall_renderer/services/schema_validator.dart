/// 解释随包发布的 Schema 子集，不接受外部规则替换。
class SchemaValidator {
  const SchemaValidator(this.root);
  final Map<String, dynamic> root;

  /// 返回精确字段路径，未知组件和未知属性均阻断整页。
  void validate(dynamic value,
      {Map<String, dynamic>? schema, String path = r'$'}) {
    final rule = schema ?? root;
    if (rule[r'$ref'] case final String ref) {
      final name = ref.substring('#/\$defs/'.length);
      validate(value, schema: root[r'$defs'][name], path: path);
      return;
    }
    if (rule['anyOf'] case final List options) {
      // 以语义组件类型选择分支，错误继续指向具体 Props。
      final type = value is Map ? value['type'] : null;
      final selected = options.where((v) => v[r'$ref'] == '#/\$defs/$type');
      if (selected.isEmpty) throw FormatException('$path: unknown_component');
      validate(value, schema: selected.first, path: path);
      return;
    }
    if (rule.containsKey('const') && value != rule['const'])
      _fail(path, 'const');
    if (rule['enum'] case final List values) {
      if (!values.contains(value)) _fail(path, 'enum');
    }
    _validateType(value, rule, path);
  }

  /// 严格检查 JSON 类型，拒绝隐式数字或字符串转换。
  void _validateType(dynamic value, Map<String, dynamic> rule, String path) {
    switch (rule['type']) {
      case 'object':
        if (value is! Map<String, dynamic>) _fail(path, 'object');
        _object(value, rule, path);
      case 'array':
        if (value is! List) _fail(path, 'array');
        _array(value, rule, path);
      case 'string':
        if (value is! String) _fail(path, 'string');
        _bounds(value.runes.length, rule, 'minLength', 'maxLength', path);
        if (rule['pattern'] case final String pattern) {
          if (!RegExp(pattern).hasMatch(value)) _fail(path, 'pattern');
        }
      case 'number':
      case 'integer':
        if (value is! num || !value.isFinite) _fail(path, 'number');
        if (rule['type'] == 'integer' && value != value.round())
          _fail(path, 'integer');
        _bounds(value, rule, 'minimum', 'maximum', path);
      case 'boolean':
        if (value is! bool) _fail(path, 'boolean');
    }
  }

  /// 先检查必需属性，再对额外属性执行白名单策略。
  void _object(
      Map<String, dynamic> value, Map<String, dynamic> rule, String path) {
    _bounds(value.length, rule, 'minProperties', 'maxProperties', path);
    final props = rule['properties'] as Map? ?? {};
    for (final key in rule['required'] as List? ?? []) {
      if (!value.containsKey(key)) _fail('$path.$key', 'required');
    }
    for (final entry in value.entries) {
      final child = props[entry.key] ?? rule['additionalProperties'];
      if (child is Map<String, dynamic>) {
        validate(entry.value, schema: child, path: '$path.${entry.key}');
      } else if (child == false) {
        _fail('$path.${entry.key}', 'unknown_field');
      }
    }
  }

  /// 列表规模与唯一性必须在生成组件前完成检查。
  void _array(List value, Map<String, dynamic> rule, String path) {
    _bounds(value.length, rule, 'minItems', 'maxItems', path);
    if (rule['uniqueItems'] == true && value.toSet().length != value.length) {
      _fail(path, 'duplicate_item');
    }
    if (rule['items'] case final Map<String, dynamic> item) {
      for (var i = 0; i < value.length; i++) {
        validate(value[i], schema: item, path: '$path[$i]');
      }
    }
  }

  /// 检查声明的数值、长度和集合大小上限。
  void _bounds(num value, Map rule, String min, String max, String path) {
    if (rule[min] is num && value < rule[min]) _fail(path, min);
    if (rule[max] is num && value > rule[max]) _fail(path, max);
  }

  /// 用 Never 保持错误后的类型收窄有效。
  Never _fail(String path, String reason) =>
      throw FormatException('$path: $reason');
}
