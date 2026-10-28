import '../../web_paywall/models/web_paywall_resource_lease.dart';
import 'dart:convert';
import 'dart:io';
import '../../web_paywall/services/web_paywall_resource_preparation.dart';
import 'package:flutter/services.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/services/web_paywall_resource_cache.dart';
import 'paywall_storage.dart';
import 'paywall_archive_queue.dart';
import '../../web_paywall/services/web_paywall_diagnostics.dart';

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
  final _queue = PaywallArchiveQueue();

  /// 包的来源和目录使用当前宿主声明复验，历史不能扩大授权范围。
  WebPaywallDocument document(Map<String, dynamic> value) =>
      WebPaywallDocument.parse(value,
          allowedOrigins: allowedOrigins,
          catalog: catalog(),
          developmentHTTPOrigin:
              environment == 'test' ? developmentHTTPOrigin : null);

  /// 同一完整包身份串行发布，不同包最多两个并行，慢包不再阻塞所有归档。
  Future<WebPaywallDocument> archive(WebPaywallDocument source,
      {bool Function()? isCurrent, WebPaywallResourceLease? resource}) {
    final key = PaywallStorage.digest(WebPaywallPackage.identity(source));
    final waiting = Stopwatch()..start();
    return WebPaywallDiagnostics.measure(
        environment,
        'archive.total',
        () => _queue.run(key, () {
              WebPaywallDiagnostics.log(environment, 'archive.acquired',
                  'key=$key queueMs=${waiting.elapsedMilliseconds} document=${source.documentId}');
              return _archive(source, isCurrent, resource);
            }),
        detail: 'key=$key document=${source.documentId}');
  }

  /// 校验和复制均使用同一冻结身份，失效请求不能激活新指针。
  Future<WebPaywallDocument> _archive(WebPaywallDocument source,
      bool Function()? isCurrent, WebPaywallResourceLease? resource) async {
    final validated = document(WebPaywallPackage.identity(source));
    final root = await directory();
    final key = PaywallStorage.digest(WebPaywallPackage.identity(validated));
    final destination = Directory('${root.path}/packages/$key');
    _protectDuringPrune(root, key);
    try {
      return await open(WebPaywallPackage.identity(validated));
    } catch (_) {/* 缺失或损坏包重新校验下载。 */}
    if (resource?.isReleased == true) throw StateError('Released resource');
    final lease = resource ??
        await cache.prepare(source, environment,
            timeout: const Duration(seconds: 120));
    Directory? temp;
    try {
      await destination.parent.create(recursive: true);
      temp = await destination.parent.createTemp('write-');
      await WebPaywallDiagnostics.measure(environment, 'archive.copy_verify',
          () => _copyAndVerify(lease.directory, temp!, validated),
          detail: 'key=$key');
      if (isCurrent != null && !isCurrent())
        throw StateError('Stale package archive');
      await _replace(temp, destination);
      return validated.withLocalDirectory(destination);
    } finally {
      if (resource == null) lease.release();
      if (temp != null && await temp.exists())
        await temp.delete(recursive: true);
    }
  }

  /// 复制目标仍完整校验；租约只省去源目录的重复摘要扫描。
  Future<void> _copyAndVerify(
      Directory source, Directory temp, WebPaywallDocument validated) async {
    final manifestFile = File('${source.path}/package.json');
    await _checkSource(manifestFile);
    final metadata = await manifestFile.readAsBytes();
    final package = WebPaywallPackage.parse(
        metadata, WebPaywallPackage.identity(validated), environment);
    for (final asset in package.files) {
      final target = File('${temp.path}/${asset['path']}');
      await target.parent.create(recursive: true);
      final original = File('${source.path}/${asset['path']}');
      await _checkSource(original);
      await original.copy(target.path);
    }
    await File('${temp.path}/package.json').writeAsBytes(metadata, flush: true);
    await cache.verifyDirectory(temp, validated, environment);
  }

  /// 租约只保护 SDK 生命周期，复制前仍拒绝源文件链接逃逸。
  Future<void> _checkSource(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != file.absolute.path) {
      throw const FileSystemException('Unsafe archive source');
    }
  }

  /// 读取成功记录指定的唯一目录，不搜索其他版本或其他环境。
  Future<WebPaywallDocument> open(Map<String, dynamic> identity) async {
    return openForPreparation(identity, null);
  }

  /// 当前展示可接走本次完整校验结果；普通读取不产生跨展示凭据。
  Future<WebPaywallDocument> openForPreparation(Map<String, dynamic> identity,
      WebPaywallResourcePreparation? preparation) async {
    // 自定义仓库保留其 open 覆写语义；只有默认仓库提供可证明的校验交接。
    if (preparation != null && runtimeType != PaywallPackageArchive)
      return open(identity);
    final parsed = document(identity);
    final root = await directory();
    final target =
        Directory('${root.path}/packages/${PaywallStorage.digest(identity)}');
    _protectDuringPrune(root, PaywallStorage.digest(identity));
    if (preparation == null) {
      await cache.verifyDirectory(target, parsed, environment);
    } else {
      await preparation.verify(target, parsed, environment, cache: cache);
      document(identity);
    }
    return parsed.withLocalDirectory(target);
  }

  /// Flutter asset 包按 manifest 提取到私有目录，再逐文件验证后使用。
  Future<WebPaywallDocument> bundled(String prefix, {AssetBundle? bundle}) =>
      _bundled(prefix, bundle, null);

  /// 默认内置资源把当前校验交给会话，自定义覆写仍由调用层复验。
  Future<WebPaywallDocument> bundledForPreparation(
      String prefix, WebPaywallResourcePreparation preparation,
      {AssetBundle? bundle}) {
    if (runtimeType != PaywallPackageArchive)
      return bundled(prefix, bundle: bundle);
    return _bundled(prefix, bundle, preparation);
  }

  /// 已提取的内置包只扫描一次；首次提取仍在原子发布前校验临时目录。
  Future<WebPaywallDocument> _bundled(String prefix, AssetBundle? bundle,
      WebPaywallResourcePreparation? preparation) async {
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
      if (preparation == null) {
        await cache.verifyDirectory(target, parsed, environment);
      } else {
        await preparation.verify(target, parsed, environment, cache: cache);
        document(identity);
      }
      return parsed.withLocalDirectory(target);
    } catch (_) {/* 首次安装时提取资产，损坏的旧提取结果不作为有效包。 */}
    await target.parent.create(recursive: true);
    final temp = await target.parent.createTemp('write-');
    try {
      await _extractBundle(assets, prefix, package, bytes, temp);
      if (preparation == null) {
        await cache.verifyDirectory(temp, parsed, environment);
        await _replace(temp, target);
      } else {
        await preparation.verifyAndPublish(temp, target, parsed, environment,
            cache: cache, publish: () => _replace(temp, target));
        document(identity);
      }
      return parsed.withLocalDirectory(target);
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  /// 只提取清单列出的资产，发布前统一验证完整目标目录。
  Future<void> _extractBundle(AssetBundle assets, String prefix,
      WebPaywallPackage package, List<int> bytes, Directory temp) async {
    for (final asset in package.files) {
      final data = await assets.load('$prefix/${asset['path']}');
      final file = File('${temp.path}/${asset['path']}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    }
    await File('${temp.path}/package.json').writeAsBytes(bytes, flush: true);
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
  static final _pruneReaders = <String, Set<String>>{};

  /// 扫描期间新读取或归档的包暂不回收，保护验证到索引提交之间的空隙。
  void _protectDuringPrune(Directory root, String key) {
    final path = root.absolute.path;
    // 扫描尚未开始时的在途归档也要保护；维护完成后不再积累记录。
    if (!_opened.containsKey(path)) _pruneReaders.putIfAbsent(path, () => {});
    _pruneReaders[path]?.add(key);
  }

  /// 每个进程只扫描一次；调用者可等待维护结束或在后台接收错误。
  Future<void> pruneOnOpen() async {
    final root = await directory();
    await _opened.putIfAbsent(root.absolute.path, () async {
      _pruneReaders.putIfAbsent(root.absolute.path, () => <String>{});
      try {
        await _prune(root);
      } finally {
        _pruneReaders.remove(root.absolute.path);
      }
    });
  }

  /// 删除前重新读取索引，并同步隔离目录，校验租约之后不留异步删除窗口。
  Future<void> _prune(Directory root) async {
    final packages = Directory('${root.path}/packages');
    if (!await packages.exists()) return;
    await for (final entry in packages.list(followLinks: false)) {
      final key = entry.path.split('/').last;
      // 上次进程在隔离后退出时，只回收专用隔离目录，不重新触碰原路径。
      if (entry is Directory &&
          RegExp(r'^[a-f0-9]{64}\.trash-[0-9]+$').hasMatch(key)) {
        await entry.delete(recursive: true);
        continue;
      }
      if (entry is! Directory || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key))
        continue;
      final kept = await _retainedPackages(root);
      if (kept == null ||
          kept.contains(key) ||
          (_pruneReaders[root.absolute.path]?.contains(key) ?? false) ||
          WebPaywallResourceLease.isInUse(entry)) continue;
      // 同步重命名只隔离目录；递归删除仍异步，不阻塞展示。
      final trash = entry.renameSync(
          '${entry.path}.trash-${DateTime.now().microsecondsSinceEpoch}');
      await trash.delete(recursive: true);
    }
  }

  /// 当前、前版与历史索引共同决定保留集；未知或损坏索引保守保留。
  Future<Set<String>?> _retainedPackages(Directory root) async {
    final records = <Map<String, dynamic>>[];
    var hasIndex = false;
    final stateFile = File('${root.path}/state.json');
    if (await stateFile.exists()) {
      try {
        final state = await PaywallStorage.read(stateFile);
        for (final key in ['current', 'previous']) {
          if (state[key] is Map)
            records.add(Map<String, dynamic>.from(state[key]));
        }
        hasIndex = true;
      } catch (_) {
        return null;
      }
    }
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
        } catch (_) {
          return null;
        }
      }
    }
    return hasIndex ? records.map(PaywallStorage.digest).toSet() : null;
  }
}
