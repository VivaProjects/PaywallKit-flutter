import 'dart:io';
import 'dart:convert';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../models/paywall_failure.dart';
import 'paywall_package_archive.dart';
import 'paywall_storage.dart';
import 'paywall_http.dart';

/// 本地入口先选择已冻结更新包，再退内置包；打开页面从不等待网络。
class PaywallLocalPackageStore {
  PaywallLocalPackageStore(
      {required this.placement,
      required Set<String> fallbackPlacements,
      required this.archive,
      required this.bundled,
      this.updateUrl,
      this.fetch,
      DateTime Function()? now})
      : fallbackPlacements = Set.unmodifiable(fallbackPlacements),
        now = now ?? DateTime.now;
  final String placement;
  final Set<String> fallbackPlacements;
  final PaywallPackageArchive archive;
  final Future<WebPaywallDocument> Function() bundled;
  final Uri? updateUrl;
  final Future<String> Function(Uri)? fetch;
  final DateTime Function() now;
  Map<String, dynamic> _state = {};
  Future<void>? _initializing;
  Future<void> _serial = Future.value();
  DateTime? _lastCheck;
  bool _checking = false;

  /// 每个仓库实例只读一次状态，失败视为首次安装而不读取其他请求的目录。
  Future<void> initialize() => _initializing ??= _restore();

  /// 原子状态中保留最高版本、拒绝列表和显式点位开关。
  Future<void> _restore() async {
    try {
      _state = await PaywallStorage.read(await _file());
      List<int>.from(_state['rejected'] as List? ?? []);
      List<String>.from(_state['disabledPlacements'] as List? ?? []);
      if ((_state['highestVersion'] as int? ?? 0) < 0 ||
          (_state['policyVersion'] as int? ?? 0) < 0)
        throw PaywallFailure.configuration;
      await archive.pruneOnOpen();
    } catch (_) {
      _state = {};
    }
  }

  /// 点位关闭优先于所有资源与历史回退。
  bool isDisabled(String name) =>
      (_state['disabledPlacements'] as List? ?? []).contains(name);
  Set<int> get _rejected => Set<int>.from(_state['rejected'] as List? ?? []);
  int get _highest => _state['highestVersion'] as int? ?? 0;

  /// 更新包失效时依次选择前版与内置包，但不尝试临时下载。
  Future<({WebPaywallDocument document, String source})> selection(
      {bool bundledOnly = false}) async {
    await initialize();
    if (!bundledOnly) {
      for (final key in ['current', 'previous']) {
        final raw = _state[key];
        if (raw is! Map<String, dynamic> || _rejected.contains(raw['revision']))
          continue;
        try {
          return (document: await archive.open(raw), source: 'update');
        } catch (_) {
          await _rejectVersion(raw['revision'] as int);
        }
      }
    }
    final value = await bundled();
    // 内置资源与更新资源都通过完整清单和摘要校验。
    if (value.localDirectory == null) throw PaywallFailure.resource;
    await archive.cache
        .verifyDirectory(value.localDirectory!, value, archive.environment);
    return (document: value, source: 'bundled');
  }

  /// 只有资源与桥故障由会话层调用拒绝，商品离线不会污染包版本。
  Future<void> reject(WebPaywallDocument document) =>
      _rejectVersion(document.revision);

  /// 拒绝状态立即持久化，下一次冷启动仍不使用坏版本。
  Future<void> _rejectVersion(int version) => _enqueue(() async {
        await initialize();
        final next = {
          ..._state,
          'rejected': [..._rejected, version].toSet().toList()
        };
        await _commit(next);
      });

  /// 每次进程首次检查，前台恢复最多每小时一次。
  Future<bool> refreshIfNeeded() async {
    if (updateUrl == null ||
        _checking ||
        (_lastCheck != null &&
            now().difference(_lastCheck!) < const Duration(hours: 1)))
      return false;
    _checking = true;
    _lastCheck = now();
    try {
      await _enqueue(_refresh);
      return true;
    } catch (_) {
      return false;
    } finally {
      _checking = false;
    }
  }

  /// 更新策略先落盘，完整资源校验成功后才替换当前包指针。
  Future<void> _refresh() async {
    await initialize();
    final uri = updateUrl!;
    _validateUrl(uri);
    final raw =
        await (fetch?.call(uri) ?? PaywallHttp.fetch(uri, limit: 256000));
    if (utf8.encode(raw).length > 256000) throw PaywallFailure.configuration;
    final update = jsonDecode(raw) as Map<String, dynamic>;
    final identity =
        WebPaywallPackage.documentForEnvironment(update, archive.environment);
    final document = archive.document(identity);
    final version = update['version'];
    final disabled = List<String>.from(update['disabledPlacements'] as List);
    if (version is! int ||
        version < 1 ||
        version != document.revision ||
        disabled.toSet().length != disabled.length)
      throw PaywallFailure.configuration;
    if (version < _highest || version < (_state['policyVersion'] as int? ?? 0))
      return;
    await _commit(
        {..._state, 'disabledPlacements': disabled, 'policyVersion': version});
    await _adopt(document, () => true);
  }

  /// 查询接口返回的兜底页面可进入同一更新仓库，旧请求不能激活新包。
  Future<void> adopt(WebPaywallDocument document,
          {bool Function()? isCurrent}) =>
      _enqueue(() => _adopt(document, isCurrent ?? () => true));

  /// 同一版本最多激活一次，失败只保留原有可用指针。
  Future<void> _adopt(
      WebPaywallDocument document, bool Function() isCurrent) async {
    await initialize();
    if (document.revision <= _highest ||
        _rejected.contains(document.revision) ||
        !isCurrent()) return;
    await archive.archive(document, isCurrent: isCurrent);
    if (!isCurrent()) throw PaywallFailure.cancelled;
    final current = _state['current'] as Map<String, dynamic>?;
    final previous = current != null && !_rejected.contains(current['revision'])
        ? current
        : _state['previous'];
    await _commit({
      ..._state,
      'previous': previous,
      'current': WebPaywallPackage.identity(document),
      'highestVersion': document.revision
    }, isCurrent: isCurrent);
  }

  /// 描述和包使用同一来源约束，生产环境拒绝开发 HTTP。
  void _validateUrl(Uri uri) {
    final http = archive.environment == 'test' &&
        !const bool.fromEnvironment('dart.vm.product') &&
        !const bool.fromEnvironment('dart.vm.profile') &&
        uri.origin == archive.developmentHTTPOrigin;
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && http)) ||
        (archive.allowedOrigins != null &&
            !archive.allowedOrigins!.contains(uri.origin)))
      throw PaywallFailure.configuration;
  }

  /// 所有指针变更串行化，归因切换不影响已展示包。
  Future<void> _enqueue(Future<void> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// 状态与资源同处独立仓库，资源 LRU 无权清除。
  Future<File> _file() async =>
      File('${(await archive.directory()).path}/state.json');

  /// 只有原子写成功才更新内存，磁盘故障不破坏旧状态。
  Future<void> _commit(Map<String, dynamic> next,
      {bool Function()? isCurrent}) async {
    await PaywallStorage.write(await _file(), next, isCurrent: isCurrent);
    _state = next;
  }
}
