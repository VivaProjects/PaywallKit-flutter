import '../../paywall_client/models/paywall_failure.dart';
import 'dart:convert';
import '../../paywall_renderer/services/paywall_store_action_policy.dart';
import 'dart:async';
import '../services/web_paywall_diagnostics.dart';
import '../services/web_paywall_interaction_policy.dart';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../paywall_renderer/models/paywall_store_product.dart';
import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import '../models/web_paywall_document.dart';
import '../models/web_paywall_resource_lease.dart';
import '../services/web_paywall_resource_cache.dart';
import '../services/web_paywall_resource_preparation.dart';
import '../models/web_paywall_environment.dart';
import '../models/web_paywall_custom.dart';
import '../models/web_paywall_session_identity.dart';
import '../models/web_paywall_session_policy.dart';

part 'web_paywall_actions.dart';
part 'web_paywall_protocol.dart';
part 'web_paywall_cached_products.dart';

/// WebView 只负责展示；价格、购买和恢复仍走宿主商店接口。
class WebPaywallController {
  WebPaywallController(
      {required this.document,
      required this.storefrontGroup,
      required this.environment,
      Map<String, dynamic> custom = const {},
      required this.bridge,
      this.sessionPolicy,
      this.onPurchaseResult,
      this.onRestoreResult,
      this.onFailure,
      this.onRenderReady,
      this.onResourceSource,
      this.onActionFailure,
      this.requiresRenderReady = false,
      this.keepSurfaceAlive = false,
      required this.allowsDismiss,
      required this.dismiss,
      required this.openLegal,
      this.resourcePreparation,
      WebPaywallResourceCache? resourceCache})
      : resourceCache = resourceCache ?? WebPaywallResourceCache.shared,
        custom = freezeWebPaywallCustom(custom) {
    // 会话创建时校验，避免在预加载后才发现宿主传入非法环境。
    environment.toPayload();
    if (document.pageUri.scheme == 'http' &&
        environment.runtimeEnvironment.name != 'test') {
      throw const FormatException('HTTP paywalls require test environment');
    }
  }

  final WebPaywallResourceCache resourceCache;
  final WebPaywallResourcePreparation? resourcePreparation;
  WebPaywallResourceLease? _resourceLease;
  Uri? _loadedPage;
  final WebPaywallDocument document;
  final String storefrontGroup;
  final WebPaywallEnvironment environment;
  final Map<String, dynamic> custom;

  /// 将环境与完整页面绑定纳入会话身份，避免跨环境复用预加载网页。
  String get sessionIdentity => webPaywallSessionIdentity(
        document: document,
        storefrontGroup: storefrontGroup,
        environment: environment,
        customIdentity: customIdentity,
      );
  String get customIdentity => jsonEncode([
        webPaywallCustomIdentity(custom),
        sessionPolicy?.purchasableProductRefs,
        sessionPolicy?.optionalProductRefs,
        sessionPolicy?.custom,
        sessionPolicy?.nextPlacement,
        allowsDismiss,
        requiresRenderReady,
        requiresStoreProducts,
        allowsStoreActions
      ]);
  PaywallPurchaseBridge bridge;
  final WebPaywallSessionPolicy? sessionPolicy;
  void Function(String, PaywallPurchaseResult)? onPurchaseResult;
  void Function(PaywallPurchaseResult)? onRestoreResult;
  void Function(PaywallFailure)? onFailure;
  void Function()? onRenderReady;
  void Function(String)? onResourceSource;
  void Function(String)? onActionFailure;
  final bool requiresRenderReady;

  /// Android 常驻表面由会话持有，失效时与桥接资源一起释放。
  final bool keepSurfaceAlive;
  VoidCallback? releaseSurface;
  final contentHeight = ValueNotifier<double?>(null);
  bool _attached = false;
  bool _productsLoading = false;
  final _productState = ValueNotifier(0);
  bool allowsDismiss;
  void Function() dismiss;
  void Function(String) openLegal;
  final failed = ValueNotifier(false);
  final ready = ValueNotifier(false);
  late final WebViewController webView;
  final Map<String, PaywallStoreProduct> _products = {};
  late final String _sessionID =
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
  final _elapsed = Stopwatch()..start();
  bool _active = true;
  bool _started = false;
  bool _bridgeReady = false;
  bool _bootstrapSent = false;
  bool _productsLoaded = false;
  bool _productsDelivered = false;
  bool _supportsDeferredProducts = false;
  int _presentationID = 0;

  /// 可选策略独立控制展示依赖与交易权限，兼容旧宿主桥。
  bool get requiresStoreProducts => bridge is PaywallStoreActionPolicy
      ? (bridge as PaywallStoreActionPolicy).requiresStoreProducts
      : bridge.requiresStoreProducts;
  bool get allowsStoreActions => bridge is PaywallStoreActionPolicy
      ? (bridge as PaywallStoreActionPolicy).allowsStoreActions
      : bridge.allowsStoreActions;

  /// 曝光保留 H5 的原始请求顺序，旧页无显式请求时返回空列表。
  List<String> get requestedProductRefs => List.unmodifiable(
      _expectsProductRequest ? _requestedProductRefs ?? const [] : const []);

  bool _expectsProductRequest = false;
  List<String>? _requestedProductRefs;
  bool _bootstrapped = false;
  bool _expectsRenderReady = false;
  bool _busy = false;
  Timer? _readyTimer;

  /// 日志关联会话和入口，不输出商品价格、custom 或原始桥消息。
  void trace(String event, [String detail = '']) {
    WebPaywallDiagnostics.log(environment.runtimeEnvironment.name, event,
        'session=$_sessionID placement=${environment.placement} document=${document.documentId} elapsedMs=${_elapsed.elapsedMilliseconds} $detail');
  }

  /// 路由接管预加载会话时才启动首屏超时；普通页面直接开始加载。
  void start() {
    if (!_active) return;
    _attached = true;
    unawaited(_sendPresentationState());
    trace("session.attach", "preloaded=$_started");
    if (_started) {
      _beginPresentationDeadline();
      _notifyPresentation();
    } else {
      _start(preloading: false);
    }
  }

  /// 高层预渲染正式挂载时开放动作，准备期间只允许握手与渲染回执。
  void attachPresentation() {
    if (!_active) return;
    _attached = true;
    unawaited(_sendPresentationState());
    _beginPresentationDeadline();
    _notifyPresentation();
  }

  /// 预热接管通过状态通知等待商品结束；取消、失败或超时均解除监听。
  Future<bool> waitForProducts(
      {required Future<void> cancelled, required Duration timeout}) async {
    if (!_active) return false;
    if (!_productsLoading) return true;
    final completed = Completer<bool>();
    void finish(bool value) {
      if (!completed.isCompleted) completed.complete(value);
    }

    void changed() {
      if (!_active)
        finish(false);
      else if (!_productsLoading) finish(true);
    }

    _productState.addListener(changed);
    final timer = Timer(timeout, () => finish(false));
    unawaited(cancelled.then((_) => finish(false)));
    try {
      changed();
      return await completed.future;
    } finally {
      timer.cancel();
      if (!_disposed) _productState.removeListener(changed);
    }
  }

  /// 商品状态变化仅通知本会话，销毁后的迟到查询不能写入已释放的监听器。
  void _setProductsLoading(bool value) {
    if (_productsLoading == value) return;
    _productsLoading = value;
    if (!_disposed) _productState.value++;
  }

  bool get awaitingProducts => _productsLoading;
  bool get isProcessing => _busy;
  bool get canRetain =>
      isReusable && ready.value && !_busy && !_productsLoading;

  /// 保留已渲染表面时关闭动作，不让未挂载的缓存页操作宿主。
  void pausePresentation() {
    // 复用页面时重置滚动与展示序号，避免继承上一次展示位置。
    if (_attached && ready.value) {
      unawaited(webView
          .runJavaScript(
              "for (const e of new Set([document.scrollingElement, ...document.querySelectorAll('*')])) { if (e && e.scrollTop) e.scrollTo({top: 0, left: e.scrollLeft, behavior: 'instant'}); }")
          .catchError((Object _) {}));
    }
    _presentationID++;
    _attached = false;
    unawaited(_sendPresentationState());
    _readyTimer?.cancel();
    _readyTimer = null;
  }

  /// 缓存交接时解除旧宿主回调，临时隐藏仍保留回调。
  void detachPresentation() {
    pausePresentation();
    onFailure = null;
    onRenderReady = null;
    onResourceSource = null;
    onActionFailure = null;
    onPurchaseResult = null;
    onRestoreResult = null;
    dismiss = () {};
    openLegal = (_) {};
  }

  /// 价格资格缓存身份由宿主确认后才复用，并重新绑定本次业务回调。
  void rebind(WebPaywallController fresh) {
    bridge = fresh.bridge;
    allowsDismiss = fresh.allowsDismiss;
    dismiss = fresh.dismiss;
    openLegal = fresh.openLegal;
    onFailure = fresh.onFailure;
    onRenderReady = fresh.onRenderReady;
    onResourceSource = fresh.onResourceSource;
    onActionFailure = fresh.onActionFailure;
    onPurchaseResult = fresh.onPurchaseResult;
    onRestoreResult = fresh.onRestoreResult;
  }

  /// 由宿主在合适场景提前调用，页面未挂载时不计首屏超时。
  void preload() => _start(preloading: true);

  /// 预加载句柄只复用仍存活且未回退的会话。
  bool get isReusable => _active && _started && !failed.value;

  /// 会话身份相同仍需验证宿主回调，防止预加载页关闭另一条路由。
  bool canReuseFor(WebPaywallController other) =>
      isReusable &&
      sessionIdentity == other.sessionIdentity &&
      identical(bridge, other.bridge) &&
      identical(dismiss, other.dismiss) &&
      identical(openLegal, other.openLegal) &&
      identical(onPurchaseResult, other.onPurchaseResult) &&
      identical(onRestoreResult, other.onRestoreResult) &&
      identical(onFailure, other.onFailure) &&
      identical(onRenderReady, other.onRenderReady) &&
      identical(onResourceSource, other.onResourceSource) &&
      identical(onActionFailure, other.onActionFailure);

  /// 未进入路由的预加载页可主动终止并释放引用。
  void destroyPreload() => dispose();

  /// 只创建一次 WebView，避免预加载与路由初始化重复导航。
  void _start({required bool preloading}) {
    if (_started || !_active) return;
    trace("session.start", "preloading=$preloading");
    _started = true;
    if (!preloading) _beginPresentationDeadline();
    webView = WebViewController();
    unawaited(_initializeWebView());
  }

  /// 屏幕外的 WebView 可能暂停渲染，正式挂载后再计十二秒。
  void _beginPresentationDeadline() {
    if (!_active || ready.value || _readyTimer != null) return;
    trace("render.deadline", "seconds=12");
    _readyTimer =
        Timer(const Duration(seconds: 12), () => _fail("render_timeout"));
  }

  /// 资源准备与桥配置并行；两者均完成后才导航，失败或销毁时归还晚到租约。
  Future<void> _initializeWebView() async {
    WebPaywallResourceLease? lease;
    try {
      await Future.wait<void>([
        WebPaywallDiagnostics.measure(environment.runtimeEnvironment.name,
            'webview.configure', _configureWebView,
            detail: 'session=$_sessionID'),
        WebPaywallDiagnostics.measure(environment.runtimeEnvironment.name,
                'webview.resource', _prepareResource,
                detail: 'session=$_sessionID')
            .then((value) {
          lease = value;
        }),
      ]);
      if (!_active) return;
      await _loadPage(lease);
      lease = null;
    } catch (_) {
      _fail();
    } finally {
      // 配置失败、超时和卸载均不能泄漏已取得或稍后取得的资源租约。
      lease?.release();
    }
  }

  /// 保持桥通道、导航代理和交互策略在首次导航前注册完成。
  Future<void> _configureWebView() async {
    try {
      await webView.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!_active) return;
      await webView.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) => _isAllowedNavigation(request.url)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onPageStarted: (_) {
          trace("navigation.start");
          // 一次会话不允许主文档重载后继续使用旧商品状态。
          if (_bridgeReady) _fail("unexpected_navigation");
        },
        onPageFinished: (_) {
          trace('navigation.finished');
          if (_active)
            unawaited(webView
                .runJavaScript(WebPaywallInteractionPolicy.script)
                .catchError((Object _) => _fail('interaction_policy')));
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true)
            _fail("navigation_code_${error.errorCode}");
        },
      ));
      if (!_active) return;
      await webView.addJavaScriptChannel('PaywallBridge',
          onMessageReceived: (message) => unawaited(_receive(message.message)));
      if (!_active) {
        await webView.removeJavaScriptChannel('PaywallBridge');
        return;
      }
      await WebPaywallInteractionPolicy.install(webView);
      if (!_active) return;
    } catch (_) {
      _fail();
      rethrow;
    }
  }

  /// 普通展示与预加载共享持久资源准备，失败仅回到当前远端页。
  Future<WebPaywallResourceLease?> _prepareResource() async {
    WebPaywallResourceLease? lease;
    try {
      lease = resourcePreparation?.take(
          document, environment.runtimeEnvironment.name);
      lease ??= await resourceCache.prepare(
          document, environment.runtimeEnvironment.name);
    } catch (_) {
      trace("resource.fallback", "source=remote");
      // 本地包失败不能转回远端下载，否则失去离线兜底语义。
      if (document.localDirectory != null) {
        _fail('resource');
        return null;
      }
      // 没有清单的旧发布仍然可以通过远端页面加载。
    } finally {
      resourcePreparation?.close();
    }
    // 资源先完成时立即交给会话持有，桥配置挂起期间卸载也能及时释放。
    if (!_active) {
      lease?.release();
      return null;
    }
    _resourceLease = lease;
    return lease;
  }

  /// 桥配置和资源准备完成后才开始导航；租约所有权交给当前会话。
  Future<void> _loadPage(WebPaywallResourceLease? lease) async {
    trace("page.load", "source=${lease == null ? 'remote' : 'disk'}");
    onResourceSource?.call(document.localDirectory != null
        ? 'local'
        : lease == null
            ? 'remote'
            : 'disk');
    _resourceLease = lease;
    _loadedPage = lease == null ? document.pageUri : Uri.file(lease.pagePath);
    if (lease == null) {
      await webView.loadRequest(document.pageUri);
    } else {
      await webView.loadFile(lease.pagePath);
    }
  }

  /// 已结束的会话和非宿主来源均禁止导航。
  bool _isAllowedNavigation(String value) {
    final uri = Uri.tryParse(value);
    final allowed = _active && uri != null && uri == _loadedPage;
    trace("navigation.policy", "allowed=$allowed");
    return allowed;
  }

  /// 销毁时取消本地等待，之后的异步结果不再写入状态或页面。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    resourcePreparation?.close();
    releaseSurface?.call();
    releaseSurface = null;
    _stop();
    contentHeight.dispose();
    failed.dispose();
    ready.dispose();
    _productState.dispose();
  }

  bool _disposed = false;

  /// 终止页面加载，不尝试取消宿主已经发起的商店交易。
  void _stop() {
    trace("session.stop", "active=$_active");
    _resourceLease?.release();
    _resourceLease = null;
    _active = false;
    _productState.value++;
    _readyTimer?.cancel();
    if (!_started) return;
    // 当前插件没有原生 stopLoading；尽力停止文档，实际隔离由 _active 保证。
    unawaited(webView.runJavaScript('window.stop()').catchError((Object _) {}));
    unawaited(webView
        .removeJavaScriptChannel('PaywallBridge')
        .catchError((Object _) {}));
  }

  /// 失败只触发一次；回退后不允许晚到结果重新激活 H5。
  void _fail([String reason = "invalid_state_or_protocol"]) {
    if (!_active) return;
    trace("session.failed", "reason=$reason");
    _stop();
    failed.value = true;
    final failure = reason.startsWith('products') ||
            (reason == 'render_timeout' && _productsLoading)
        ? PaywallFailure.productsUnavailable
        : reason == 'render_timeout'
            ? PaywallFailure.renderTimeout
            : reason == 'resource' || reason.startsWith('navigation')
                ? PaywallFailure.resource
                : PaywallFailure.bridge;
    onFailure?.call(failure);
  }

  /// 先关闭交互门禁，由宿主决定保留就绪页面或销毁，避免提前停止破坏缓存。
  void close() {
    if (!allowsDismiss || !_active || !_attached || _busy) return;
    _attached = false;
    unawaited(_sendPresentationState());
    dismiss();
  }

  /// 验证 JS 接收器已执行，避免可选调用静默丢弃初始化数据。
  Future<void> _send(Map<String, Object?> message) async {
    trace("bridge.send", "type=${message['type']} active=$_active");
    if (!_active) return;
    try {
      final result = await webView.runJavaScriptReturningResult(
          "typeof window.PaywallRuntime?.receive === 'function' && (window.PaywallRuntime.receive(${jsonEncode(message)}), true)");
      if (!_active) return;
      if (result != true && result != 'true') _fail('javascript_delivery');
    } catch (_) {
      _fail();
    }
  }
}
