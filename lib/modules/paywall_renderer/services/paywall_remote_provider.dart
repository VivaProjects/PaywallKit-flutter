import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../models/paywall_catalog.dart';
import '../models/paywall_event.dart';
import '../models/paywall_remote_options.dart';
import '../models/paywall_resolution.dart';
import '../models/paywall_snapshot.dart';
import 'paywall_configuration_service.dart';
import 'paywall_signature_verifier.dart';

class PaywallRemoteProvider {
  PaywallRemoteProvider(this.options, {this.onConfigurationError})
      : verifier = PaywallSignatureVerifier(options.publicKeys);
  final PaywallRemoteOptions options;
  final void Function(PaywallEvent)? onConfigurationError;
  final PaywallSignatureVerifier verifier;
  List<int>? _manifest;
  String? _etag;

  /// 返回独立不可变快照；已展示页面不会订阅清单变化。
  Future<PaywallResolution> resolve(
      {required String placement,
      required String installationId,
      required String locale,
      required String storefrontGroup,
      required Map<String, PaywallCatalog> catalogs,
      required Set<String> assetIDs,
      String bundledAsset =
          'packages/native_paywall/assets/onboarding.json'}) async {
    final context = _ResolveContext(
        placement, installationId, locale, storefrontGroup, catalogs, assetIDs);
    final failures = <String>[];
    var paused = false;
    try {
      return await _remote(context, failures);
    } catch (error) {
      failures.add(error.toString());
      paused = error is _Paused;
    }
    if (!paused) {
      try {
        return await _cached(context, failures);
      } catch (error) {
        failures.add(error.toString());
      }
    }
    return _bundled(failures, bundledAsset, placement, locale, storefrontGroup,
        catalogs, assetIDs);
  }

  /// 远端验证成功后原子保存，暂停标记也需要跨进程保留。
  Future<PaywallResolution> _remote(
      _ResolveContext c, List<String> failures) async {
    final manifestData = await _fetchManifest();
    final manifest = await _decodeManifest(manifestData, true);
    final plan = manifest['placements'][c.placement];
    if (plan == null) throw const FormatException('placement_missing');
    if (plan['paused'] == true) {
      try {
        await _save(c.placement, {
          'manifest': base64Encode(manifestData),
          'document': '',
          'reference': plan['stable']
        });
      } catch (_) {
        failures.add('pause_cache_write_failed');
      }
      throw _Paused();
    }
    final choice = _choose(plan, c.installationId);
    final (bytes, snapshot) = await _downloadValidated(c, choice);
    // 完整的领域树构造成功后才更新 LKG，磁盘失败不会撤销已验证页面。
    try {
      await _save(c.placement, {
        'manifest': base64Encode(manifestData),
        'document': base64Encode(bytes),
        'reference': choice.$1
      });
    } catch (_) {
      failures.add('cache_write_failed');
    }
    return PaywallResolution(
        snapshot, PaywallResolutionSource.remote, failures);
  }

  /// 仅报告已验证 Manifest 绑定的失败版本，避免错误归因给兜底页。
  Future<(List<int>, PaywallSnapshot)> _downloadValidated(
      _ResolveContext c, (Map, Map<String, String>) choice) async {
    var category = 'network';
    try {
      final bytes = (await _fetch(choice.$1['path'])).$1;
      category = 'configuration';
      final snapshot = await _snapshot(bytes, choice.$1, c.placement, c.locale,
          c.storefront, c.catalogs, c.assets, choice.$2);
      return (bytes, snapshot);
    } catch (error) {
      try {
        onConfigurationError
            ?.call(PaywallEvent(PaywallEventName.paywallConfigFallback, {
          'app': options.app,
          'environment': options.environment,
          'placement': c.placement,
          'documentId': choice.$1['documentId'],
          'revision': choice.$1['revision'],
          'errorCategory': category,
          'reason': error.toString(),
          ...choice.$2,
        }));
      } catch (_) {/* 分析失败不能打断兜底。 */}
      rethrow;
    }
  }

  /// 旧缓存必须重新验证签名来源，并重新计算同一实验的分配。
  Future<PaywallResolution> _cached(
      _ResolveContext c, List<String> failures) async {
    final cache = await _read(c.placement);
    final manifest =
        await _decodeManifest(base64Decode(cache['manifest']), false);
    final plan = manifest['placements'][c.placement];
    if (plan == null || plan['paused'] == true)
      throw const FormatException('cache_scope');
    final choice = _choose(plan, c.installationId);
    if (choice.$1['sha256'] != cache['reference']['sha256'])
      throw const FormatException('cache_assignment');
    final snapshot = await _snapshot(
        base64Decode(cache['document']),
        cache['reference'],
        c.placement,
        c.locale,
        c.storefront,
        c.catalogs,
        c.assets,
        choice.$2);
    return PaywallResolution(
        snapshot, PaywallResolutionSource.lastKnownGood, failures);
  }

  /// 包内失败后交由宿主固定原生支付墙，避免渲染残缺 JSON 页面。
  Future<PaywallResolution> _bundled(
      List<String> failures,
      String asset,
      String placement,
      String locale,
      String storefront,
      Map<String, PaywallCatalog> catalogs,
      Set<String> assets) async {
    try {
      final snapshot = await PaywallConfigurationService().loadBundled(
          asset: asset,
          placement: placement,
          locale: locale,
          storefrontGroup: storefront,
          catalogs: catalogs,
          assetIDs: assets);
      return PaywallResolution(
          snapshot, PaywallResolutionSource.bundled, failures);
    } catch (error) {
      failures.add(error.toString());
    }
    return PaywallResolution(null, PaywallResolutionSource.native, failures);
  }

  /// 先验签与绑定摘要，再进入协议校验和领域模型转换。
  Future<PaywallSnapshot> _snapshot(
      List<int> bytes,
      Map ref,
      String placement,
      String locale,
      String storefront,
      Map<String, PaywallCatalog> catalogs,
      Set<String> assets,
      Map<String, String> assignment) async {
    if (verifier.digest(bytes) != ref['sha256'] ||
        ref['path'] !=
            '/documents/${ref['documentId']}/revisions/${ref['revision']}') {
      throw const FormatException('document_hash_or_path');
    }
    final payload = await verifier.payload(bytes);
    final schema = jsonDecode(await rootBundle
        .loadString('packages/native_paywall/assets/paywall.schema.json'));
    final components = jsonDecode(await rootBundle
        .loadString('packages/native_paywall/assets/component-catalog.json'));
    final snapshot = PaywallSnapshot.validateTrusted(
        utf8.decode(payload), schema, components,
        placement: placement,
        locale: locale,
        storefrontGroup: storefront,
        catalogs: catalogs,
        assetIDs: assets,
        assignment: assignment);
    if (snapshot.documentId != ref['documentId'] ||
        snapshot.revision != ref['revision'])
      throw const FormatException('revision_mismatch');
    return snapshot;
  }

  /// 清单在 TTL 内缓存；过期后允许服务端返回 ETag 304。
  Future<List<int>> _fetchManifest() async {
    if (_manifest != null) {
      try {
        await _decodeManifest(_manifest!, true);
        return _manifest!;
      } catch (_) {/* 过期或坏缓存重新拉取。 */}
    }
    final response = await _fetch(
        '/manifests/${options.app}/${options.environment}',
        etag: _etag);
    final data =
        response.$3 == 304 && _manifest != null ? _manifest! : response.$1;
    await _decodeManifest(data, true);
    _manifest = data;
    _etag = response.$2;
    return data;
  }

  /// 限制总请求耗时、响应体和 origin，拒绝自动重定向。
  Future<(List<int>, String?, int)> _fetch(String path, {String? etag}) async {
    final base = options.baseUri;
    final local = options.allowLoopbackHttp &&
        base.scheme == 'http' &&
        ['localhost', '127.0.0.1', '::1'].contains(base.host);
    final uri = base.resolve(path);
    if ((base.scheme != 'https' && !local) ||
        !path.startsWith('/') ||
        path.contains('..') ||
        uri.origin != base.origin ||
        uri.hasQuery ||
        uri.hasFragment) throw const FormatException('untrusted_url');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        if (etag != null) request.headers.set('If-None-Match', etag);
        final response = await request.close();
        if (![200, 304].contains(response.statusCode))
          throw const FormatException('http_status');
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 400000)
            throw const FormatException('response_limit');
          bytes.addAll(chunk);
        }
        return (bytes, response.headers.value('ETag'), response.statusCode);
      })()
          .timeout(const Duration(seconds: 2));
    } finally {
      client.close(force: true);
    }
  }

  /// 只信任本应用、本环境和有效期受限的签名清单。
  Future<Map<String, dynamic>> _decodeManifest(
      List<int> bytes, bool fresh) async {
    final manifest = jsonDecode(utf8.decode(await verifier.payload(bytes)));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (manifest['app'] != options.app ||
        manifest['environment'] != options.environment ||
        manifest['issuedAt'] is! int ||
        manifest['expiresAt'] is! int ||
        manifest['issuedAt'] > now + 60 ||
        manifest['expiresAt'] <= manifest['issuedAt'] ||
        manifest['expiresAt'] - manifest['issuedAt'] > 900 ||
        (fresh && manifest['expiresAt'] <= now)) {
      throw const FormatException('manifest_context_or_expiry');
    }
    for (final plan in (manifest['placements'] as Map).values) {
      if (plan['basisPoints'] is! int ||
          plan['basisPoints'] < 0 ||
          plan['basisPoints'] > 10000)
        throw const FormatException('invalid_traffic');
    }
    return Map<String, dynamic>.from(manifest);
  }

  /// 同一安装与实验固定分桶，调整比例只改变候选纳入阈值。
  (Map, Map<String, String>) _choose(Map plan, String installationId) {
    if (plan['candidate'] == null || plan['experimentId'] == null)
      return (plan['stable'], {'source': 'stable'});
    final bucket = verifier.bucket(installationId, plan['experimentId']);
    final candidate = bucket < plan['basisPoints'];
    return (
      candidate ? plan['candidate'] : plan['stable'],
      {
        'experimentId': plan['experimentId'],
        'bucket': '$bucket',
        'source': candidate ? 'candidate' : 'stable'
      }
    );
  }

  File _file(String placement) {
    final key =
        '${options.baseUri}|${options.app}|${options.environment}|$placement|1.0';
    return File(
        '${options.cacheDirectory.path}/${verifier.digest(utf8.encode(key))}.json');
  }

  /// 先写独立临时文件再替换，避免并发或中断产生半份缓存。
  Future<void> _save(String placement, Map value) async {
    await options.cacheDirectory.create(recursive: true);
    final file = _file(placement);
    final temporary =
        File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// 缓存是非可信输入，每次读出后都会再次验签。
  Future<Map> _read(String placement) async {
    final file = _file(placement);
    if (await file.length() > 1100000)
      throw const FormatException('cache_size');
    return jsonDecode(await file.readAsString());
  }
}

// 单次解析上下文只供服务内部传递，不暴露可变页面状态。
class _ResolveContext {
  _ResolveContext(this.placement, this.installationId, this.locale,
      this.storefront, this.catalogs, this.assets);
  final String placement, installationId, locale, storefront;
  final Map<String, PaywallCatalog> catalogs;
  final Set<String> assets;
}

class _Paused implements Exception {
  @override
  String toString() => 'placement_paused';
}
