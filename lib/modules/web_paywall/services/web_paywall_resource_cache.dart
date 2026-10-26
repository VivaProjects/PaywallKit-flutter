import '../../paywall_client/models/paywall_http_failure.dart';
import 'dart:async';
import 'web_paywall_diagnostics.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import '../models/web_paywall_document.dart';
import '../models/web_paywall_package.dart';
import '../models/web_paywall_resource_lease.dart';

/// 持久化静态资源，不储存价格、优惠资格或桥接会话。
class WebPaywallResourceCache {
  WebPaywallResourceCache(
      {Future<Directory> Function()? directory,
      this.download,
      this.capacityBytes = 300 * 1024 * 1024,
      this.downloadTimeout = const Duration(seconds: 6)})
      : _directory = directory ?? _nativeDirectory;
  static final shared = WebPaywallResourceCache();
  final Future<Directory> Function() _directory;
  final int capacityBytes;
  final Duration downloadTimeout;
  final Future<List<int>> Function(Uri, int, DateTime)? download;
  Future<Directory>? _root;
  final _pending = <String, Future<Directory>>{};
  final _deleting = <String, Future<void>>{};
  Future<void>? _pruning;
  final _leases = <String, int>{};
  final _pins = <String, int>{};
  final _waiters = <Completer<void>>[];
  int _downloads = 0;

  /// 平台插件返回已排除系统备份的应用私有目录。
  static Future<Directory> _nativeDirectory() async {
    final path = await const MethodChannel('native_paywall/resources')
        .invokeMethod<String>('directory');
    if (path == null) throw const FileSystemException('Cache unavailable');
    return Directory(path);
  }

  /// 同版请求合并，租约覆盖等待下载到页面卸载的整个阶段。
  Future<WebPaywallResourceLease> prepare(
      WebPaywallDocument document, String environment,
      {Duration? timeout}) async {
    if (!['test', 'production'].contains(environment)) {
      throw const FormatException('Invalid environment');
    }
    final identity = WebPaywallPackage.identity(document);
    if (document.localDirectory != null) {
      await verifyDirectory(document.localDirectory!, document, environment);
      return WebPaywallResourceLease(document.localDirectory!, () {});
    }
    final key = sha256
        .convert(utf8.encode(jsonEncode([identity, environment])))
        .toString();
    WebPaywallDiagnostics.log(environment, "resource.prepare",
        "key=$key shared=${_pending[key] != null}");
    if (_deleting[key] != null) await _deleting[key];
    _pins[key] = (_pins[key] ?? 0) + 1;
    Future<Directory>? pending;
    try {
      // 所有调用者共享一个 Future；清理不能删除等待挂载的包。
      pending = _pending.putIfAbsent(
          key,
          () =>
              _resolve(key, identity, environment, timeout ?? downloadTimeout));
      final directory = await pending;
      if (identical(_pending[key], pending)) _pending.remove(key);
      _leases[key] = (_leases[key] ?? 0) + 1;
      WebPaywallDiagnostics.log(
          environment, "resource.lease", "key=$key count=${_leases[key]}");
      return WebPaywallResourceLease(
          directory, () => _release(key, environment));
    } catch (error) {
      WebPaywallDiagnostics.log(environment, "resource.failed",
          "key=$key error=${error.runtimeType}");
      if (identical(_pending[key], pending)) _pending.remove(key);
      _unpin(key);
      rethrow;
    }
  }

  /// 旧缓存迁移只读取完整磁盘包，不允许隐式下载。
  Future<WebPaywallResourceLease> cached(
      WebPaywallDocument document, String environment) async {
    final identity = WebPaywallPackage.identity(document);
    final key = sha256
        .convert(utf8.encode(jsonEncode([identity, environment])))
        .toString();
    if (_deleting[key] != null) await _deleting[key];
    _pins[key] = (_pins[key] ?? 0) + 1;
    try {
      final root = await _storageRoot();
      final directory = Directory('${root.path}/$key');
      await verifyDirectory(directory, document, environment);
      _leases[key] = (_leases[key] ?? 0) + 1;
      return WebPaywallResourceLease(
          directory, () => _release(key, environment));
    } catch (_) {
      _unpin(key);
      rethrow;
    }
  }

  /// 本地包与历史包同样逐文件校验，不能因来自磁盘就跳过摘要检查。
  Future<void> verifyDirectory(Directory directory, WebPaywallDocument document,
          String environment) =>
      _verify(directory, WebPaywallPackage.identity(document), environment);

  /// 手动清理仅影响空闲资源，活跃会话保持原版本。
  Future<void> clear() => _prune(0);

  /// 最后一个使用者结束后尝试容量清理，清理失败不影响关闭。
  void _release(String key, String environment) {
    WebPaywallDiagnostics.log(environment, "resource.release", "key=$key");
    _leases[key] = ((_leases[key] ?? 1) - 1).clamp(0, 1 << 30);
    _unpin(key);
  }

  /// 失败的等待者只释放预留，不影响已交付租约。
  void _unpin(String key) {
    _pins[key] = ((_pins[key] ?? 1) - 1).clamp(0, 1 << 30);
    unawaited(_prune(capacityBytes).catchError((Object _) {}));
  }

  /// 初始化私有根目录并删除上次进程中断留下的临时包。
  Future<Directory> _prepareRoot() async {
    final root = await _directory();
    await root.create(recursive: true);
    if (await root.resolveSymbolicLinks() != root.absolute.path) {
      throw const FileSystemException('Unsafe root');
    }
    await for (final entity in root.list(followLinks: false)) {
      if (entity.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('tmp-')) {
        await entity.delete(recursive: true);
      }
    }
    return root;
  }

  /// 临时目录初始化失败可以重试，不把一次平台错误冻结到整个进程。
  Future<Directory> _storageRoot() async {
    final pending = _root ??= _prepareRoot();
    try {
      return await pending;
    } catch (_) {
      if (identical(_root, pending)) _root = null;
      rethrow;
    }
  }

  /// 命中时重新校验文件，损坏资源不允许继续展示。
  Future<Directory> _resolve(String key, Map<String, dynamic> identity,
      String environment, Duration timeout) async {
    final root = await _storageRoot();
    final directory = Directory('${root.path}/$key');
    try {
      await _verify(directory, identity, environment);
      await File('${directory.path}/package.json')
          .setLastModified(DateTime.now());
      WebPaywallDiagnostics.log(environment, "resource.hit", "key=$key");
      return directory;
    } catch (error) {
      WebPaywallDiagnostics.log(environment, "resource.miss", "key=$key");
      if (await directory.exists()) {
        WebPaywallDiagnostics.log(
            environment, "resource.invalid", "key=$key error=$error");
        if ((_leases[key] ?? 0) > 0) rethrow;
        await directory.delete(recursive: true);
      }
    }
    // 两个页面并行；同页文件按顺序下载，避免瞬间占满连接。
    WebPaywallDiagnostics.log(
        environment, "resource.download_wait", "key=$key active=$_downloads");
    await _acquire();
    try {
      return await _download(root, directory, identity, environment, timeout);
    } finally {
      _finish();
    }
  }

  /// 下载槽位直接交给排队者，避免新请求插队超出上限。
  Future<void> _acquire() async {
    if (_downloads < 2) {
      _downloads++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  /// 释放下载槽位或唤醒下一个页面。
  void _finish() {
    if (_waiters.isEmpty) {
      _downloads--;
    } else {
      _waiters.removeAt(0).complete();
    }
  }

  /// 响应按块限流读取，禁止重定向和超出清单大小的响应。
  Future<List<int>> _fetch(Uri uri, int limit, DateTime deadline) async {
    if (download != null) return download!(uri, limit, deadline);
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) throw TimeoutException('Package deadline');
    final client = HttpClient()..connectionTimeout = remaining;
    var timedOut = false;
    final timer = Timer(remaining, () {
      timedOut = true;
      client.close(force: true);
    });
    try {
      final request = await client.getUrl(uri).timeout(remaining);
      request.followRedirects = false;
      final response = await request.close().timeout(remaining);
      if (response.statusCode != 200) {
        throw PaywallHttpFailure(response.statusCode);
      }
      if (response.contentLength > limit) {
        throw const HttpException('Invalid package response');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > limit)
          throw const FormatException('Resource too large');
        bytes.addAll(chunk);
      }
      return bytes;
    } catch (_) {
      if (timedOut) throw TimeoutException('Paywall download deadline');
      rethrow;
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }

  /// 临时目录校验完成后重命名，不会留下半更新页面。
  Future<Directory> _download(
      Directory root,
      Directory destination,
      Map<String, dynamic> identity,
      String environment,
      Duration timeout) async {
    WebPaywallDiagnostics.log(environment, 'resource.download_start',
        'key=${destination.path.split('/').last}');
    final temporary = await root.createTemp('tmp-');
    final base = Uri.parse(identity['pageUrl'] as String).resolve('.');
    final deadline = DateTime.now().add(timeout);
    try {
      final bytes =
          await _fetch(base.resolve('package.json'), 256000, deadline);
      final package = WebPaywallPackage.parse(bytes, identity, environment);
      for (final asset in package.files) {
        final data =
            await _fetch(base.resolve(asset['path']), asset['size'], deadline);
        if (data.length != asset['size'] ||
            sha256.convert(data).toString() != asset['sha256']) {
          throw FormatException('Resource hash mismatch: ${asset['path']}');
        }
        final file = File('${temporary.path}/${asset['path']}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data, flush: true);
      }
      await File('${temporary.path}/package.json')
          .writeAsBytes(bytes, flush: true);
      final result = await temporary.rename(destination.path);
      WebPaywallDiagnostics.log(environment, "resource.download_ready",
          "key=${destination.path.split('/').last} files=${package.files.length}");
      await _prune(capacityBytes);
      return result;
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }

  /// 检查本地文件不是链接且大小吻合，再进行摘要校验。
  Future<List<int>> _readFile(File file, int size, {bool exact = true}) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != file.absolute.path) {
      throw const FileSystemException('Unsafe resource');
    }
    final length = await file.length();
    if (length > size || (exact && length != size))
      throw FormatException(
          'Invalid resource size: ${file.path} expected=$size actual=$length');
    return file.readAsBytes();
  }

  /// 只校验当前配置的包，不搜索历史版本。
  Future<void> _verify(Directory directory, Map<String, dynamic> identity,
      String environment) async {
    final bytes = await _readFile(
        File('${directory.path}/package.json'), 256000,
        exact: false);
    final package = WebPaywallPackage.parse(bytes, identity, environment);
    for (final asset in package.files) {
      final data = await _readFile(
          File('${directory.path}/${asset['path']}'), asset['size']);
      if (sha256.convert(data).toString() != asset['sha256'])
        throw FormatException('Corrupt resource: ${asset['path']}');
    }
  }

  /// 依据最后命中时间淘汰空闲包，活跃包可暂时超过容量。
  Future<void> _prune(int limit) async {
    while (_pruning != null) {
      await _pruning;
    }
    final task = _pruneFiles(limit);
    _pruning = task;
    try {
      await task;
    } finally {
      _pruning = null;
    }
  }

  /// 跨启动清理按包自身的显式环境记录，损坏元数据不启用日志。
  Future<String> _packageEnvironment(Directory directory) async {
    try {
      final metadata = jsonDecode(
          await File('${directory.path}/package.json').readAsString());
      if (metadata is Map && metadata['runtimeEnvironment'] is String) {
        return metadata['runtimeEnvironment'] as String;
      }
    } catch (_) {
      // 日志读取失败不阻断原有清理。
    }
    return '';
  }

  /// 串行清理避免多个租约同时释放时重复删除目录。
  Future<void> _pruneFiles(int limit) async {
    if (_root == null) return;
    final root = await _root!;
    final entries = <({Directory directory, int size, DateTime date})>[];
    await for (final entity in root.list(followLinks: false)) {
      final key = entity.path.split('/').last;
      if (entity is! Directory || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key))
        continue;
      var size = 0;
      await for (final file
          in entity.list(recursive: true, followLinks: false)) {
        if (file is File) size += await file.length();
      }
      final stat = await File('${entity.path}/package.json').stat();
      entries.add((directory: entity, size: size, date: stat.modified));
    }
    entries.sort((a, b) => a.date.compareTo(b.date));
    var total = entries.fold(0, (int sum, e) => sum + e.size);
    for (final entry in entries) {
      if (total <= limit) break;
      if ((_pins[entry.directory.path.split('/').last] ?? 0) > 0) continue;
      final key = entry.directory.path.split('/').last;
      final environment = await _packageEnvironment(entry.directory);
      // 读取诊断信息期间可能产生新租约，删除前重新检查以保持缓存边界。
      if ((_pins[key] ?? 0) > 0) continue;
      final deletion =
          entry.directory.delete(recursive: true).then<void>((_) {});
      _deleting[key] = deletion;
      try {
        await deletion;
        WebPaywallDiagnostics.log(environment, "resource.evicted",
            "key=$key bytes=${entry.size} limit=$limit");
      } finally {
        _deleting.remove(key);
      }
      total -= entry.size;
    }
  }
}
