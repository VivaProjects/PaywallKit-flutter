import '../../web_paywall/models/web_paywall_resource_lease.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/services/web_paywall_resource_cache.dart';
import 'paywall_storage.dart';

/// 独立归档完整包，普通资源缓存清理不会删除兜底或成功版本。
class PaywallPackageArchive {
  PaywallPackageArchive(
      {required this.directory,
      required this.environment,
      required this.catalog,
      required this.allowedOrigins,
      this.developmentHTTPOrigin,
      WebPaywallResourceCache? cache})
      // 下载、归档和展示必须共享租约与临时目录生命周期，不能各自清理同一根目录。
      : cache = cache ?? WebPaywallResourceCache.shared;
  final Future<Directory> Function() directory;
  final String environment;
  final PaywallCatalog Function() catalog;
  final Set<String>? allowedOrigins;
  final String? developmentHTTPOrigin;
  final WebPaywallResourceCache cache;
  Future<void> _serial = Future.value();

  /// 包的来源和目录使用当前宿主声明复验，历史不能扩大授权范围。
  WebPaywallDocument document(Map<String, dynamic> value) =>
      WebPaywallDocument.parse(value,
          allowedOrigins: allowedOrigins,
          catalog: catalog(),
          developmentHTTPOrigin:
              environment == 'test' ? developmentHTTPOrigin : null);

  /// 下载完成后保存独立副本；串行提交避免同版本并发改写。
  Future<WebPaywallDocument> archive(WebPaywallDocument source,
      {bool Function()? isCurrent}) {
    final result = _serial.then((_) => _archive(source, isCurrent));
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// 校验和复制均使用同一冻结身份，失效请求不能激活新指针。
  Future<WebPaywallDocument> _archive(
      WebPaywallDocument source, bool Function()? isCurrent) async {
    final validated = document(WebPaywallPackage.identity(source));
    final root = await directory();
    final key = PaywallStorage.digest(WebPaywallPackage.identity(validated));
    final destination = Directory('${root.path}/packages/$key');
    try {
      return await open(WebPaywallPackage.identity(validated));
    } catch (_) {/* 缺失或损坏包重新校验下载。 */}
    final lease = await cache.prepare(source, environment,
        timeout: const Duration(seconds: 120));
    await destination.parent.create(recursive: true);
    final temp = await destination.parent.createTemp('write-');
    try {
      final metadata =
          await File('${lease.directory.path}/package.json').readAsBytes();
      final package = WebPaywallPackage.parse(
          metadata, WebPaywallPackage.identity(validated), environment);
      for (final asset in package.files) {
        final target = File('${temp.path}/${asset['path']}');
        await target.parent.create(recursive: true);
        await File('${lease.directory.path}/${asset['path']}')
            .copy(target.path);
      }
      await File('${temp.path}/package.json')
          .writeAsBytes(metadata, flush: true);
      await cache.verifyDirectory(temp, validated, environment);
      if (isCurrent != null && !isCurrent())
        throw StateError('Stale package archive');
      await _replace(temp, destination);
      return validated.withLocalDirectory(destination);
    } finally {
      lease.release();
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  /// 读取成功记录指定的唯一目录，不搜索其他版本或其他环境。
  Future<WebPaywallDocument> open(Map<String, dynamic> identity) async {
    final parsed = document(identity);
    final root = await directory();
    final target =
        Directory('${root.path}/packages/${PaywallStorage.digest(identity)}');
    await cache.verifyDirectory(target, parsed, environment);
    return parsed.withLocalDirectory(target);
  }

  /// Flutter asset 包按 manifest 提取到私有目录，再逐文件验证后使用。
  Future<WebPaywallDocument> bundled(String prefix,
      {AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final raw = await assets.load('$prefix/package.json');
    final bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
    final manifest = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final identity =
        WebPaywallPackage.documentForEnvironment(manifest, environment);
    final parsed = document(identity);
    final package = WebPaywallPackage.parse(bytes, identity, environment);
    final root = await directory();
    final target =
        Directory('${root.path}/bundled/${PaywallStorage.digest(identity)}');
    try {
      await cache.verifyDirectory(target, parsed, environment);
      return parsed.withLocalDirectory(target);
    } catch (_) {/* 首次安装时提取资产，损坏的旧提取结果不作为有效包。 */}
    await target.parent.create(recursive: true);
    final temp = await target.parent.createTemp('write-');
    try {
      for (final asset in package.files) {
        final data = await assets.load('$prefix/${asset['path']}');
        final file = File('${temp.path}/${asset['path']}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }
      await File('${temp.path}/package.json').writeAsBytes(bytes, flush: true);
      await cache.verifyDirectory(temp, parsed, environment);
      await _replace(temp, target);
      return parsed.withLocalDirectory(target);
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  /// 损坏副本在完整新包准备后替换，活跃 WebView 仍持有目录时拒绝改写。
  Future<void> _replace(Directory temporary, Directory destination) async {
    if (await destination.exists()) {
      if (WebPaywallResourceLease.isInUse(destination))
        throw const FileSystemException('Package in use');
      final backup = await destination.rename(
          '${destination.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}');
      try {
        await temporary.rename(destination.path);
      } catch (_) {
        await backup.rename(destination.path);
        rethrow;
      }
      await backup.delete(recursive: true);
    } else {
      await temporary.rename(destination.path);
    }
  }

  static final _opened = <String, Future<void>>{};

  /// 每个进程首次打开归档时回收失去索引的版本，之后不删除可能被会话选中的包。
  Future<void> pruneOnOpen() async {
    final root = await directory();
    final task = _opened.putIfAbsent(root.path, () => _prune(root));
    await task;
  }

  /// 当前/前版指针与所有成功索引共同决定保留集，活跃租约额外保护。
  Future<void> _prune(Directory root) async {
    final kept = <String>{};
    final records = <Map<String, dynamic>>[];
    var hasIndex = false;
    try {
      final state = await PaywallStorage.read(File('${root.path}/state.json'));
      for (final key in ['current', 'previous']) {
        if (state[key] is Map)
          records.add(Map<String, dynamic>.from(state[key] as Map));
      }
      hasIndex = true;
    } catch (_) {/* 没有本地更新状态时只检查历史索引。 */}
    final indices = Directory('${root.path}/indices');
    if (await indices.exists()) {
      await for (final file in indices.list(followLinks: false)) {
        if (file is! File) continue;
        try {
          for (final record
              in (await PaywallStorage.read(file))['records'] as List) {
            records.add(
                Map<String, dynamic>.from((record as Map)['document'] as Map));
          }
          hasIndex = true;
        } catch (_) {/* 损坏索引不提供可复用版本。 */}
      }
    }
    if (!hasIndex) return;
    kept.addAll(records.map(PaywallStorage.digest));
    final packages = Directory('${root.path}/packages');
    if (!await packages.exists()) return;
    await for (final entry in packages.list(followLinks: false)) {
      if (entry is Directory &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.path.split('/').last) &&
          !kept.contains(entry.path.split('/').last) &&
          !WebPaywallResourceLease.isInUse(entry)) {
        await entry.delete(recursive: true);
      }
    }
  }
}
