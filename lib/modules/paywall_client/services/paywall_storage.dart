import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// SDK 私有持久目录；业务仓库各自维护键与状态，不借用资源 LRU。
class PaywallStorage {
  PaywallStorage({Future<Directory> Function()? directory})
      : _directory = directory ?? nativeDirectory;
  final Future<Directory> Function() _directory;

  /// 两个平台插件返回排除系统备份的应用目录。
  static Future<Directory> nativeDirectory() async {
    final path = await const MethodChannel('native_paywall/resources')
        .invokeMethod<String>('directory');
    if (path == null) throw const FileSystemException('Storage unavailable');
    return Directory(path);
  }

  /// 使用摘要隔离宿主、请求和环境，外部字符串不能构造磁盘路径。
  static String digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// 仓库目录不接受符号链接，避免从私有存储跳转到外部位置。
  Future<Directory> folder(String kind, String scope) async {
    if (!RegExp(r'^[a-z_]+$').hasMatch(kind))
      throw const FormatException('Invalid store kind');
    final root = await _directory();
    final target = Directory('${root.path}/$kind/${digest(scope)}');
    await target.create(recursive: true);
    if (await target.resolveSymbolicLinks() != target.absolute.path)
      throw const FileSystemException('Unsafe store');
    return target;
  }

  /// 读取有界 JSON 状态；调用方决定损坏状态的业务兜底。
  static Future<Map<String, dynamic>> read(File file,
      {int limit = 3000000}) async {
    if (await file.length() > limit ||
        await file.resolveSymbolicLinks() != file.absolute.path) {
      throw const FormatException('Invalid state file');
    }
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  /// 临时写入再原子替换，旧状态不会被半写文件覆盖。
  static Future<void> write(File file, Object value,
      {bool Function()? isCurrent}) async {
    await file.parent.create(recursive: true);
    final temp = await file.parent.createTemp('write-');
    try {
      final staged = File('${temp.path}/state.json');
      await staged.writeAsString(jsonEncode(value), flush: true);
      if (isCurrent != null && !isCurrent())
        throw StateError('Stale storage write');
      await staged.rename(file.path);
    } finally {
      await temp.delete(recursive: true);
    }
  }
}
