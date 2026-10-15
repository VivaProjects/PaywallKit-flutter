import 'dart:convert';
import 'web_paywall_document.dart';

/// 已验证的资源清单，始终使用远端文档身份而非本地路径。
class WebPaywallPackage {
  WebPaywallPackage(this.files);
  final List<Map<String, dynamic>> files;

  /// 身份包含版本与完整商品绑定，禁止借用旧页或另一环境。
  static Map<String, dynamic> identity(WebPaywallDocument document) => {
        'kind': 'web-paywall',
        'bridgeVersion': 2,
        'documentId': document.documentId,
        'revision': document.revision,
        'pageUrl': document.pageUri.toString(),
        'catalogKey': document.catalogKey,
        'productRefs': document.productRefs,
        'initialProductRef': document.initialProductRef,
      };

  /// 只接受普通相对路径，拒绝编码、隐藏目录和父目录跳转。
  static bool validPath(String path) =>
      RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_./-]*$').hasMatch(path) &&
      path.split('/').every((part) =>
          part.isNotEmpty &&
          part != '.' &&
          part != '..' &&
          !part.startsWith('.'));

  /// 网络和磁盘命中共用清单校验，先限制总量再读取文件。
  static WebPaywallPackage parse(
      List<int> bytes, Map<String, dynamic> expected, String environment) {
    if (bytes.length > 256000) throw const FormatException('Package too large');
    final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final document = {
      ...documentForEnvironment(value, environment),
      'pageUrl': expected['pageUrl']
    };
    if (value['entry'] != 'offline.html' ||
        document.length != expected.length ||
        expected.keys.any(
            (key) => jsonEncode(document[key]) != jsonEncode(expected[key]))) {
      throw const FormatException('Package identity mismatch');
    }
    return _validateFiles(
        (value['files'] as List).cast<Map<String, dynamic>>());
  }

  /// 共享包只共享静态资源，每个环境必须拥有完整且独立的商品绑定。
  static Map<String, dynamic> documentForEnvironment(
      Map<String, dynamic> value, String environment) {
    if (!['test', 'production'].contains(environment))
      throw const FormatException('Invalid environment');
    final document = Map<String, dynamic>.from(value['document'] as Map);
    if (value['formatVersion'] == 1 &&
        value['runtimeEnvironment'] == environment) return document;
    final documents = value['documents'];
    if (value['formatVersion'] != 2 ||
        value['runtimeEnvironment'] != 'shared' ||
        documents is! Map ||
        documents.length != 2 ||
        !documents.containsKey('test') ||
        !documents.containsKey('production') ||
        !_sameDocument(
            document, Map<String, dynamic>.from(documents['test'] as Map))) {
      throw const FormatException('Invalid shared package');
    }
    // 两套绑定必须对应同一页面和版本，不允许环境缺失后跨环境回退。
    for (final entry in documents.values) {
      final candidate = Map<String, dynamic>.from(entry as Map);
      final refs = candidate['productRefs'];
      if ([
            'kind',
            'bridgeVersion',
            'documentId',
            'revision',
            'pageUrl',
            'catalogKey'
          ].any((key) => candidate[key] != document[key]) ||
          refs is! List ||
          refs.isEmpty ||
          refs.any((ref) => ref is! String) ||
          refs.toSet().length != refs.length ||
          !refs.contains(candidate['initialProductRef'])) {
        throw const FormatException('Invalid shared binding');
      }
    }
    return Map<String, dynamic>.from(documents[environment] as Map);
  }

  /// 字典字段顺序不影响商品绑定身份。
  static bool _sameDocument(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a.length == b.length &&
      a.keys.every((key) => jsonEncode(a[key]) == jsonEncode(b[key]));

  /// 限制资源集大小并检查路径唯一性。
  static WebPaywallPackage _validateFiles(List<Map<String, dynamic>> files) {
    // 限制文件数、单文件大小与总量，重复路径不能覆盖已校验资源。
    if (files.isEmpty || files.length > 1000)
      throw const FormatException('Invalid files');
    final names = <String>{};
    var total = 0;
    for (final file in files) {
      final path = file['path'] as String;
      final size = file['size'];
      if (!validPath(path) ||
          path == 'package.json' ||
          !names.add(path) ||
          size is! int ||
          size < 0 ||
          size > 100 * 1024 * 1024 ||
          file['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(file['sha256'])) {
        throw const FormatException('Invalid resource');
      }
      total += size;
    }
    if (total > 100 * 1024 * 1024 ||
        !names.containsAll(
            ['offline.html', 'offline.js', 'content.json', 'page.json'])) {
      throw const FormatException('Incomplete package');
    }
    return WebPaywallPackage(files);
  }
}
