import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../../paywall_renderer/models/paywall_catalog.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../models/paywall_configuration_request.dart';
import 'paywall_http.dart';
import '../../web_paywall/services/web_paywall_diagnostics.dart';

/// 独立 SDK 配置来源，网络与离线副本应用相同目录和来源校验。
class PaywallConfigurationSource {
  PaywallConfigurationSource(
      {required this.cacheNamespace,
      required Set<String>? allowedOrigins,
      required this.catalogs,
      required this.request,
      this.transform,
      this.developmentHTTPOrigin,
      this.fetch,
      this.directory})
      : allowedOrigins =
            allowedOrigins == null ? null : Set.unmodifiable(allowedOrigins);
  final String cacheNamespace;
  final Set<String>? allowedOrigins;
  final Map<String, PaywallCatalog> Function() catalogs;
  final Future<PaywallConfigurationRequest> Function() request;
  final Future<String> Function(String, PaywallConfigurationRequest)? transform;
  final String? developmentHTTPOrigin;
  final Future<String> Function(PaywallConfigurationRequest)? fetch;
  final Future<Directory> Function()? directory;

  /// 只在 Debug/Test 放行显式开发来源，发布环境始终要求 HTTPS。
  String? developmentOrigin(PaywallConfigurationRequest request) =>
      !const bool.fromEnvironment('dart.vm.product') &&
              !const bool.fromEnvironment('dart.vm.profile') &&
              request.environment.runtimeEnvironment.name == 'test'
          ? developmentHTTPOrigin
          : null;

  /// 查询运行时复用来源约束，不能绕过 HTTPS 与开发地址检查。
  void validateRequest(PaywallConfigurationRequest request) =>
      _validateRequest(request);

  /// 兼容合并版本的缓存读取入口，仍使用原有身份和校验。
  Future<WebPaywallConfiguration> readCached(
          PaywallConfigurationRequest request) =>
      cached(request);

  /// 启动迁移只读取当前确切请求的缓存，来源和商品目录仍重新校验。
  Future<WebPaywallConfiguration> cached(
      PaywallConfigurationRequest request) async {
    _validateRequest(request);
    final file = await _file(request);
    if (await file.length() > 1000000)
      throw const FormatException('Cache too large');
    return WebPaywallConfiguration.parse(await file.readAsString(),
        allowedOrigins: allowedOrigins,
        catalogs: catalogs(),
        developmentHTTPOrigin: developmentOrigin(request));
  }

  /// 完整校验后才原子写缓存；旧请求失效时既不写入也不读回退。
  Future<WebPaywallConfiguration> load(PaywallConfigurationRequest request,
      {required bool Function() isCurrent}) async {
    _validateRequest(request);
    final catalogSnapshot = catalogs();
    WebPaywallConfiguration parse(String raw) =>
        WebPaywallConfiguration.parse(raw,
            allowedOrigins: allowedOrigins,
            catalogs: catalogSnapshot,
            developmentHTTPOrigin: developmentOrigin(request));
    try {
      WebPaywallDiagnostics.log(
          request.environment.runtimeEnvironment.name,
          'configuration.request',
          '${request.method} ${request.uri} ${request.body ?? ""}');
      final response = await (fetch?.call(request) ??
          PaywallHttp.fetch(request.uri,
              method: request.method, body: request.body));
      WebPaywallDiagnostics.log(request.environment.runtimeEnvironment.name,
          'configuration.response', response);
      final raw =
          transform == null ? response : await transform!(response, request);
      _checkCurrent(isCurrent);
      final configuration = parse(raw);
      // 磁盘不可写不应使已验证的网络配置失效。
      try {
        await _save(request, raw, isCurrent);
      } on FileSystemException {/* 下次联网重试持久化。 */} on PlatformException {
        /* 插件不可用时继续当前有效响应。 */
      } on MissingPluginException {/* 无平台存储时保留当前有效响应。 */}
      _checkCurrent(isCurrent);
      return configuration;
    } catch (error, stack) {
      _checkCurrent(isCurrent);
      return _readFallback(request, parse, isCurrent, error, stack);
    }
  }

  /// 离线副本不可用时保留原始错误，避免磁盘错误掩盖请求失败原因。
  Future<WebPaywallConfiguration> _readFallback(
      PaywallConfigurationRequest request,
      WebPaywallConfiguration Function(String) parse,
      bool Function() isCurrent,
      Object error,
      StackTrace stack) async {
    try {
      final file = await _file(request);
      if (await file.length() > 1000000)
        throw const FormatException('Cache too large');
      final cached = parse(await file.readAsString());
      _checkCurrent(isCurrent);
      return cached;
    } catch (_) {
      _checkCurrent(isCurrent);
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// 请求字段不能携带无效环境或未经授权的 HTTP 地址。
  void _validateRequest(PaywallConfigurationRequest request) {
    final uri = request.uri;
    request.environment.toPayload();
    if (!['GET', 'POST'].contains(request.method) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                uri.origin == developmentOrigin(request)))) {
      throw const FormatException('Invalid configuration request');
    }
  }

  /// 新刷新或销毁会话后，所有旧异步结果必须丢弃。
  void _checkCurrent(bool Function() isCurrent) {
    if (!isCurrent()) throw StateError('Stale paywall configuration request');
  }

  /// 配置存放在资源目录的独立子目录，不参与静态包 LRU 清理。
  Future<File> _file(PaywallConfigurationRequest request) async {
    final root = directory != null
        ? await directory!()
        : Directory((await const MethodChannel('native_paywall/resources')
            .invokeMethod<String>('directory'))!);
    final folder = Directory('${root.path}/configuration');
    await folder.create(recursive: true);
    return File('${folder.path}/${request.identity(cacheNamespace)}.json');
  }

  /// 临时文件写完后再替换，避免进程中断留下半份 JSON。
  Future<void> _save(PaywallConfigurationRequest request, String raw,
      bool Function() isCurrent) async {
    final file = await _file(request);
    final temporary = await file.parent.createTemp('write-');
    try {
      final staged = File('${temporary.path}/configuration.json');
      await staged.writeAsBytes(utf8.encode(raw), flush: true);
      _checkCurrent(isCurrent);
      await staged.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}
