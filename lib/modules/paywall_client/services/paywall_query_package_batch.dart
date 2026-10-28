import 'dart:async';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_resource_lease.dart';
import '../../web_paywall/services/web_paywall_package_loader.dart';

/// 查询批次拥有下载租约；最后一个别名交付结束就释放，避免被其他慢包长期占用。
class PaywallQueryPackageBatch {
  PaywallQueryPackageBatch(
      Iterable<String> addresses, WebPaywallPackageLoader? customLoader) {
    for (final address in addresses) {
      _remaining[address] = (_remaining[address] ?? 0) + 1;
    }
    // 自定义加载器仍走原 load；默认加载器把租约交由当前批次管理。
    loader = customLoader ??
        WebPaywallPackageLoader(onPrepared: (doc, lease) {
          resources[doc] = lease;
        });
  }
  late final WebPaywallPackageLoader loader;
  final resources = <WebPaywallDocument, WebPaywallResourceLease>{};
  final _loaded = <String, Future<WebPaywallDocument>>{};
  final _remaining = <String, int>{};

  /// 同一地址只启动一次重试操作，所有点位共享成功或失败结果。
  Future<WebPaywallDocument> load(String address,
      Future<WebPaywallDocument> Function(WebPaywallPackageLoader) operation) {
    return _loaded.putIfAbsent(address, () {
      final task = operation(loader);
      // 预取失败可能早于交付，立即接住异常；交付时仍收到原始失败。
      unawaited(task.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      return task;
    });
  }

  /// 批次异常退出也等在途预取结束，确保不会在释放之后留下迟到租约。
  Future<void> settle() async {
    await Future.wait(_loaded.values.map((task) =>
        task.then<void>((_) {}, onError: (Object _, StackTrace __) {})));
  }

  /// 归档回调退出后归还一位使用者；最终使用者释放源包，不等待无关下载。
  Future<void> finish(
      String address, Future<WebPaywallDocument> pending) async {
    final remaining = (_remaining[address] ?? 1) - 1;
    _remaining[address] = remaining;
    if (remaining != 0) return;
    try {
      final doc = await pending;
      resources.remove(doc)?.release();
    } catch (_) {
      // 下载失败已经由点位处理；批次退出时兜底释放可能留下的资源。
    }
  }

  /// 异常退出同样释放尚未交付的资源，释放操作可重复调用。
  void dispose() {
    for (final resource in resources.values) {
      resource.release();
    }
    resources.clear();
  }
}
