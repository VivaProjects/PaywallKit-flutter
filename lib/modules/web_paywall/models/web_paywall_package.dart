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
    final document = value['document'] as Map<String, dynamic>;
    if (value['formatVersion'] != 1 ||
        value['runtimeEnvironment'] != environment ||
        value['entry'] != 'offline.html' ||
        document.length != expected.length ||
        expected.keys.any(
            (key) => jsonEncode(document[key]) != jsonEncode(expected[key]))) {
      throw const FormatException('Package identity mismatch');
    }
    return _validateFiles(
        (value['files'] as List).cast<Map<String, dynamic>>());
  }

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
