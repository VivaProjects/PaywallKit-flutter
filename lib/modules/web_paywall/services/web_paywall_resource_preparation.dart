import 'dart:convert';
import 'dart:io';
import '../models/web_paywall_document.dart';
import '../models/web_paywall_package.dart';
import '../models/web_paywall_resource_lease.dart';
import 'web_paywall_resource_verifier.dart';
import 'web_paywall_resource_cache.dart';

/// 单次加载持有已验证目录，不能跨展示或重试复用验证结果。
final class WebPaywallResourcePreparation {
  final _leases = <String, WebPaywallResourceLease>{};
  bool _closed = false;

  /// 校验前占用目录，失败、取消或迟到结果均释放；没有外部标记成功的入口。
  Future<void> verify(
      Directory directory, WebPaywallDocument document, String environment,
      {WebPaywallResourceCache? cache}) async {
    final lease = WebPaywallResourceLease(directory, () {});
    var transferred = false;
    try {
      if (cache == null) {
        await WebPaywallResourceVerifier.verify(
            directory.path, WebPaywallPackage.identity(document), environment);
      } else {
        // 宿主附加的资源校验继续执行，交接只省去后续重复准备。
        await cache.verifyDirectory(directory, document, environment);
      }
      if (!_closed) {
        final key = _key(directory, document, environment);
        _leases.remove(key)?.release();
        _leases[key] = lease;
        transferred = true;
      }
    } finally {
      if (!transferred) lease.release();
    }
  }

  /// 临时包完整校验后原子发布，同次凭据随目录迁移，不重复扫描文件。
  Future<void> verifyAndPublish(Directory temporary, Directory destination,
      WebPaywallDocument document, String environment,
      {required WebPaywallResourceCache cache,
      required Future<void> Function() publish}) async {
    await verify(temporary, document, environment, cache: cache);
    try {
      await publish();
      final verified = _leases.remove(_key(temporary, document, environment));
      if (verified == null) return; // 取消已释放凭据，不让迟到发布重新持有资源。
      verified.release();
      if (!_closed) {
        final key = _key(destination, document, environment);
        _leases.remove(key)?.release();
        _leases[key] = WebPaywallResourceLease(destination, () {});
      }
    } catch (_) {
      _leases.remove(_key(temporary, document, environment))?.release();
      rethrow;
    }
  }

  /// 同次加载的内置包可沿用已完成的验证，外部加载结果仍完整校验。
  Future<void> verifyIfNeeded(
      Directory directory, WebPaywallDocument document, String environment,
      {WebPaywallResourceCache? cache}) async {
    if (!_closed &&
        _leases.containsKey(_key(directory, document, environment))) {
      return;
    }
    await verify(directory, document, environment, cache: cache);
  }

  /// 只消费相同完整身份和环境的结果；商品收窄或目录变化继续走正常校验。
  WebPaywallResourceLease? take(
      WebPaywallDocument document, String environment) {
    if (_closed || document.localDirectory == null) return null;
    final lease =
        _leases.remove(_key(document.localDirectory!, document, environment));
    close();
    return lease;
  }

  /// 由流程或网页释放未消费的资源，可重复关闭，晚到校验不会重新填入。
  void close() {
    _closed = true;
    for (final lease in _leases.values) {
      lease.release();
    }
    _leases.clear();
  }

  /// 页面地址、版本、绑定、环境与实际目录共同限定交接身份。
  String _key(Directory directory, WebPaywallDocument document,
          String environment) =>
      jsonEncode([
        directory.absolute.path,
        environment,
        WebPaywallPackage.identity(document)
      ]);
}
