import 'dart:io';
import '../../web_paywall/models/web_paywall_document.dart';
import '../../web_paywall/models/web_paywall_package.dart';
import 'paywall_package_archive.dart';
import 'paywall_storage.dart';
import '../../web_paywall/services/web_paywall_resource_preparation.dart';

/// 每个请求、环境、入口和页面只保留最近两个首屏成功版本的索引。
class PaywallHistoryStore {
  PaywallHistoryStore({required this.archive});
  final PaywallPackageArchive archive;
  Future<void> _serial = Future.value();

  /// 只有首屏成功且完整资源可归档时提交，取消不会更新索引。
  Future<void> record(
      {required String requestIdentity,
      required String placement,
      required WebPaywallDocument document,
      required String configuration,
      required bool Function() isCurrent}) {
    final result = _serial.then((_) => _record(
        requestIdentity, placement, document, configuration, isCurrent));
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// 同版本内容不可覆盖已成功记录，迟到的旧版本也不会替代更新记录。
  Future<void> _record(
      String request,
      String placement,
      WebPaywallDocument document,
      String configuration,
      bool Function() isCurrent) async {
    await archive.pruneOnOpen();
    final file = await _index(request, placement, document.documentId);
    final records = await _records(file);
    if (records.any((record) =>
        (record['document'] as Map)['revision'] == document.revision)) return;
    await archive.archive(document, isCurrent: isCurrent);
    if (!isCurrent()) return;
    records.add({
      'document': WebPaywallPackage.identity(document),
      'configuration': configuration
    });
    records.sort((a, b) => ((b['document'] as Map)['revision'] as int)
        .compareTo((a['document'] as Map)['revision'] as int));
    await PaywallStorage.write(file, {'records': records.take(2).toList()},
        isCurrent: isCurrent);
  }

  /// 最多尝试一个同文档较低版本；损坏历史交由上层退本地包。
  Future<({WebPaywallDocument document, String configuration})?> previous(
      {required String requestIdentity,
      required String placement,
      required WebPaywallDocument current,
      WebPaywallResourcePreparation? preparation}) async {
    await archive.pruneOnOpen();
    final records = await _records(
        await _index(requestIdentity, placement, current.documentId));
    final older = records
        .where((record) =>
            (record['document'] as Map)['documentId'] == current.documentId &&
            ((record['document'] as Map)['revision'] as int) < current.revision)
        .toList();
    older.sort((a, b) => ((b['document'] as Map)['revision'] as int)
        .compareTo((a['document'] as Map)['revision'] as int));
    if (older.isEmpty) return null;
    final record = older.first;
    return (
      document: await (preparation == null
          ? archive.open(Map<String, dynamic>.from(record['document'] as Map))
          : archive.openForPreparation(
              Map<String, dynamic>.from(record['document'] as Map),
              preparation)),
      configuration: record['configuration'] as String
    );
  }

  /// 不从普通磁盘包推测成功状态，索引损坏视为无历史。
  Future<List<Map<String, dynamic>>> _records(File file) async {
    try {
      final records = List<Map<String, dynamic>>.from(
          (await PaywallStorage.read(file))['records'] as List);
      return records.length <= 2 ? records : [];
    } catch (_) {
      return [];
    }
  }

  /// 归档目录已经隔离宿主和环境，请求与入口继续参与组身份。
  Future<File> _index(
          String request, String placement, String document) async =>
      File(
          '${(await archive.directory()).path}/indices/${PaywallStorage.digest([
            request,
            placement,
            document
          ])}.json');
}
