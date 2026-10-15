import 'dart:convert';
import 'dart:async';
import '../services/web_paywall_diagnostics.dart';

import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../paywall_renderer/models/paywall_store_product.dart';
import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import '../models/web_paywall_document.dart';
import '../models/web_paywall_resource_lease.dart';
import '../services/web_paywall_resource_cache.dart';
import '../models/web_paywall_environment.dart';
import '../models/web_paywall_custom.dart';
import '../models/web_paywall_session_identity.dart';

/// WebView 只负责展示；价格、购买和恢复仍走宿主商店接口。
class WebPaywallController extends GetxController {
  WebPaywallController(
      {required this.document,
      required this.storefrontGroup,
      required this.environment,
      Map<String, dynamic> custom = const {},
      required this.bridge,
      required this.allowsDismiss,
      required this.dismiss,
      required this.openLegal,
      WebPaywallResourceCache? resourceCache})
      : resourceCache = resourceCache ?? WebPaywallResourceCache.shared,
        custom = freezeWebPaywallCustom(custom);

  final WebPaywallResourceCache resourceCache;
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
  String get customIdentity => webPaywallCustomIdentity(custom);
  final PaywallPurchaseBridge bridge;
  final bool allowsDismiss;
  final void Function() dismiss;
  final void Function(String) openLegal;
  final failed = false.obs;
  final ready = false.obs;
  late final WebViewController webView;
  final Map<String, PaywallStoreProduct> _products = {};
  late final String _sessionID =
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
  final _elapsed = Stopwatch()..start();
  bool _active = true;
  bool _started = false;
  bool _bridgeReady = false;
  bool _bootstrapSent = false;
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
  @override
  void onInit() {
    super.onInit();
    trace("session.attach", "preloaded=$_started");
    if (_started) {
      _beginPresentationDeadline();
    } else {
      _start(preloading: false);
    }
  }

  /// 由宿主在合适场景提前调用，页面未挂载时不计首屏超时。
  void preload() => _start(preloading: true);

  /// 预加载句柄只复用仍存活且未回退的会话。
  bool get isReusable => _active && _started && !failed.value;

  /// 未进入路由的预加载页可主动终止并释放引用。
  void destroyPreload() => _stop();

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

  /// 等桥接配置完成后才开始导航，防止页面 ready 早于通道注册。
  Future<void> _initializeWebView() async {
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
      await _loadPage();
    } catch (_) {
      _fail();
    }
  }

  /// 普通展示与预加载共享持久资源准备，失败仅回到当前远端页。
  Future<void> _loadPage() async {
    WebPaywallResourceLease? lease;
    try {
      lease = await resourceCache.prepare(
          document, environment.runtimeEnvironment.name);
    } catch (_) {
      trace("resource.fallback", "source=remote");
      // 没有清单的旧发布仍然可以通过远端页面加载。
    }
    if (!_active) {
      lease?.release();
      return;
    }
    trace("page.load", "source=${lease == null ? 'remote' : 'disk'}");
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

  /// 销毁时取消本地等待，之后的异步结果不再写入 Rx 状态或页面。
  @override
  void onClose() {
    _stop();
    super.onClose();
  }

  /// 终止页面加载，不尝试取消宿主已经发起的商店交易。
  void _stop() {
    trace("session.stop", "active=$_active");
    _resourceLease?.release();
    _resourceLease = null;
    _active = false;
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
  }

  /// 用户关闭后立刻阻断桥接，避免路由销毁之前继续投递消息。
  void close() {
    if (!allowsDismiss || !_active) return;
    _stop();
    dismiss();
  }

  /// 限制消息大小和指令集，且只执行目录中已解析的商品。
  Future<void> _receive(String raw) async {
    if (!_active || raw.length > 2048) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final type = decoded['type'];
    if ([
      'ready',
      'productsRequest',
      'bootstrapped',
      'renderReady',
      'renderFailed',
      'purchase',
      'restore',
      'close',
      'terms',
      'privacy'
    ].contains(type)) {
      trace('bridge.received', 'type=$type');
    }
    await _handleEvent(type, decoded);
  }

  /// 已校验的桥消息按原有状态门禁执行，日志不改变动作权限。
  Future<void> _handleEvent(Object? type, Map<String, dynamic> decoded) async {
    switch (type) {
      case 'ready':
        if (_bridgeReady) return;
        if (decoded['bridgeVersion'] != 2) {
          _fail();
          return;
        }
        _bridgeReady = true;
        final capabilities = decoded['capabilities'];
        _expectsRenderReady =
            capabilities is List && capabilities.contains('renderReady');
        _expectsProductRequest =
            capabilities is List && capabilities.contains('productRequest');
        await _sendSessionContext();
      case 'productsRequest':
        await _receiveProductRequest(decoded);
      case 'bootstrapped':
        if (!_acceptsReceipt(decoded)) return;
        _bootstrapped = true;
        if (!_expectsRenderReady) _finishRendering();
      case 'renderReady':
        if (_expectsRenderReady && _bootstrapped && _acceptsReceipt(decoded)) {
          _finishRendering();
        }
      case 'renderFailed':
        if (_acceptsReceipt(decoded) ||
            (_bridgeReady && decoded['sessionID'] == _sessionID)) _fail();
      case 'purchase':
        await _purchase(decoded['productRef']);
      case 'restore':
        await _restore();
      case 'close':
        close();
      case 'terms':
        openLegal('terms');
      case 'privacy':
        openLegal('privacy');
    }
  }

  /// 环境先发送给页面，旧页在 ready 后沿用发布清单。
  Future<void> _sendSessionContext() async {
    if (_expectsProductRequest) {
      await _send({
        'type': 'sessionContext',
        'bridgeVersion': 2,
        'sessionID': _sessionID,
        'custom': {...custom, ...environment.toPayload()}
      });
    } else {
      _requestedProductRefs = document.productRefs;
      await _loadProducts();
    }
  }

  /// 页面请求必须精确匹配当前会话、环境和清单，禁止重复查询。
  Future<void> _receiveProductRequest(Map<String, dynamic> event) async {
    if (!_active ||
        !_bridgeReady ||
        !_expectsProductRequest ||
        _requestedProductRefs != null) return;
    final refs = event['productRefs'];
    // 查询前验证所有字段；不接受跨环境和清单之外的商品。
    if (event['bridgeVersion'] != 2 ||
        event['sessionID'] != _sessionID ||
        event['runtimeEnvironment'] != environment.runtimeEnvironment.name ||
        refs is! List ||
        refs.isEmpty ||
        refs.any((ref) => ref is! String) ||
        refs.toSet().length != refs.length ||
        refs.length > document.productRefs.length ||
        !refs.every(document.productRefs.contains)) {
      _fail('invalid_product_request');
      return;
    }
    _requestedProductRefs = refs.cast<String>();
    await _loadProducts();
  }

  /// 页面商品请求通过校验后查询商店，完成后只注入一次。
  Future<void> _loadProducts() async {
    trace("products.start", "requested=${_requestedProductRefs?.length ?? 0}");
    try {
      final values =
          await bridge.products(_requestedProductRefs!, storefrontGroup);
      if (!_active) return;
      _products.clear();
      for (final product in values) {
        if (_requestedProductRefs!.contains(product.productRef)) {
          _products[product.productRef] = product;
        }
      }
      trace("products.loaded",
          "matched=${_products.length} requested=${_requestedProductRefs?.length ?? 0}");
      if (_products.isEmpty) {
        _fail("products_empty");
        return;
      }
      await _bootstrapIfPossible();
    } catch (error) {
      trace("products.failed", "error=${error.runtimeType}");
      _fail("products_query");
    }
  }

  /// 桥与商品同时就绪才注入，重复 ready 不会重复查询或重置交易状态。
  Future<void> _bootstrapIfPossible() async {
    if (!_active || !_bridgeReady || _products.isEmpty || _bootstrapSent) {
      return;
    }
    _bootstrapSent = true;
    final visible =
        _requestedProductRefs!.where(_products.containsKey).map((ref) {
      final product = _products[ref]!;
      return {
        'productRef': ref,
        'displayPrice': product.displayPrice,
        'disclosure': product.disclosure,
        if (product.periodText != null) 'periodText': product.periodText,
        if (product.dailyPriceText != null)
          'dailyPriceText': product.dailyPriceText,
        if (product.introductoryPriceText != null)
          'introductoryPriceText': product.introductoryPriceText,
        if (product.isEligibleForFreeTrial != null)
          'isEligibleForFreeTrial': product.isEligibleForFreeTrial
      };
    }).toList();
    await _send({
      'type': 'bootstrap',
      'bridgeVersion': 2,
      'sessionID': _sessionID,
      'custom': {...custom, ...environment.toPayload()},
      'products': visible
    });
  }

  /// 新页面必须返回本次会话标识，旧页面继续允许无标识回执。
  bool _acceptsReceipt(Map<String, dynamic> event) {
    if (!_active || !_bootstrapSent) return false;
    if (event.containsKey('sessionID')) return event['sessionID'] == _sessionID;
    return !_expectsRenderReady;
  }

  /// 收到适用协议的完成回执后才移除加载遮罩。
  void _finishRendering() {
    if (!_active || ready.value) return;
    _readyTimer?.cancel();
    trace("render.ready");
    ready.value = true;
  }

  /// 只允许已展示且未处理交易的会话调用宿主购买。
  Future<void> _purchase(Object? ref) async {
    if (!_active ||
        !ready.value ||
        _busy ||
        ref is! String ||
        !_products.containsKey(ref)) return;
    trace("action.start", "type=purchase");
    _busy = true;
    try {
      final result = await bridge.purchase(_products[ref]!);
      trace('action.result', 'type=purchase result=${result.name}');
      await _send({'type': 'purchaseResult', 'result': result.name});
    } catch (_) {
      trace('action.result', 'type=purchase result=failed');
      await _send({'type': 'purchaseResult', 'result': 'failed'});
    } finally {
      _busy = false;
    }
  }

  /// 恢复与购买互斥，结果只投递给仍存活的会话。
  Future<void> _restore() async {
    if (!_active || !ready.value || _busy) return;
    trace("action.start", "type=restore");
    _busy = true;
    try {
      final result = await bridge.restore();
      trace('action.result', 'type=restore result=${result.name}');
      await _send({'type': 'restoreResult', 'result': result.name});
    } catch (_) {
      trace('action.result', 'type=restore result=failed');
      await _send({'type': 'restoreResult', 'result': 'failed'});
    } finally {
      _busy = false;
    }
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
