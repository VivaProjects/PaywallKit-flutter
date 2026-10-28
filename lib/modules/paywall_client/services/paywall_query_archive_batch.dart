import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import '../../web_paywall/models/web_paywall_resource_lease.dart';
import 'paywall_package_archive.dart';
import 'paywall_storage.dart';

/// 一次查询共享完整包的归档结果；下一批次和下次启动仍重新校验。
class PaywallQueryArchiveBatch {
  final _archives =
      <PaywallPackageArchive, Map<String, Future<WebPaywallDocument>>>{};

  /// 别名点位仍检查当前目录授权，只有物理包复制和摘要验证可以合并。
  Future<WebPaywallDocument> save(
      PaywallPackageArchive archive,
      WebPaywallDocument document,
      bool Function() isCurrent,
      WebPaywallResourceLease? resource) async {
    final identity = WebPaywallPackage.identity(document);
    archive.document(identity);
    if (!isCurrent()) throw StateError('Stale archive batch');
    final key = PaywallStorage.digest(identity);
    final packages = _archives.putIfAbsent(archive, () => {});
    final pending = packages.putIfAbsent(
        key,
        () => archive.archive(document,
            isCurrent: isCurrent, resource: resource));
    final WebPaywallDocument result;
    try {
      result = await pending;
    } catch (_) {
      // 仅共享成功结果；失败后后续别名仍有原有的归档尝试机会。
      if (identical(packages[key], pending)) packages.remove(key);
      rethrow;
    }
    // 等待期间宿主可撤销商品授权，复用已校验资源不能跳过这个检查。
    archive.document(identity);
    if (!isCurrent()) throw StateError('Stale archive batch');
    return result;
  }
}
