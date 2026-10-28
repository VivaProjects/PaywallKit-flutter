import 'dart:io';
import 'web_paywall_diagnostics.dart';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import '../models/web_paywall_package.dart';

/// 文件完整性工作只接收可传递数据，不捕获会话、平台通道或宿主对象。
class WebPaywallResourceVerifier {
  /// 整包在一个后台 isolate 内读取，所有安全检查完成后才返回。
  static Future<void> verify(String directory, Map<String, dynamic> identity,
          String environment) =>
      WebPaywallDiagnostics.measure(environment, 'resource.verify',
          () => Isolate.run(() => _verify(directory, identity, environment)),
          detail:
              'document=${identity['documentId']} revision=${identity['revision']}');

  /// 清单和资源均拒绝链接逃逸、大小不符及摘要损坏。
  static void _verify(
      String directory, Map<String, dynamic> identity, String environment) {
    final bytes =
        _readFile(File('$directory/package.json'), 256000, exact: false);
    final package = WebPaywallPackage.parse(bytes, identity, environment);
    for (final asset in package.files) {
      final data =
          _readFile(File('$directory/${asset['path']}'), asset['size']);
      if (sha256.convert(data).toString() != asset['sha256']) {
        throw FormatException('Corrupt resource: ${asset['path']}');
      }
    }
  }

  /// 使用同步文件 API 仅限后台 isolate，读取前仍检查路径和大小。
  static List<int> _readFile(File file, int size, {bool exact = true}) {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.resolveSymbolicLinksSync() != file.absolute.path) {
      throw const FileSystemException('Unsafe resource');
    }
    final length = file.lengthSync();
    if (length > size || (exact && length != size)) {
      throw FormatException('Invalid resource size: ${file.path}');
    }
    return file.readAsBytesSync();
  }
}
