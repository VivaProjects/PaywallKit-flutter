part of 'web_paywall_controller.dart';

/// 桥握手和渲染回执与交易动作分离。
extension WebPaywallProtocol on WebPaywallController {
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
        await _receiveReady(decoded);
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
      case 'contentHeight':
        final height = decoded['height'];
        if (_acceptsReceipt(decoded) &&
            decoded['sessionID'] == _sessionID &&
            height is num &&
            height.isFinite &&
            height > 0 &&
            height <= 100000) {
          contentHeight.value = height.toDouble();
        }
      case 'purchase':
        await _purchase(decoded['productRef']);
      case 'restore':
        await _restore();
      case 'close':
        close();
      case 'terms':
        if (_attached) openLegal('terms');
      case 'privacy':
        if (_attached) openLegal('privacy');
    }
  }

  /// ready 只握手一次，完整能力组合决定是否允许商品延迟补齐。
  Future<void> _receiveReady(Map<String, dynamic> decoded) async {
    if (_bridgeReady) return;
    if (decoded['bridgeVersion'] != 2) {
      _fail();
      return;
    }
    _bridgeReady = true;
    final capabilities = decoded['capabilities'];
    _expectsRenderReady =
        capabilities is List && capabilities.contains('renderReady');
    if (requiresRenderReady && !_expectsRenderReady) {
      _fail();
      return;
    }
    _expectsProductRequest =
        capabilities is List && capabilities.contains('productRequest');
    // 冷启动等严格入口必须取得报价后初始化，不能用空商品首屏提前完成门禁。
    _supportsDeferredProducts = !environment.waitsForProducts &&
        _expectsProductRequest &&
        _expectsRenderReady &&
        capabilities is List &&
        capabilities.contains('deferredProducts');
    await _sendSessionContext();
  }

  /// 环境先发送给页面，旧页在 ready 后沿用发布清单。
  Future<void> _sendSessionContext() async {
    if (_expectsProductRequest) {
      await _send({
        'type': 'sessionContext',
        'bridgeVersion': 2,
        'sessionID': _sessionID,
        'custom': {
          ...?sessionPolicy?.custom,
          ...custom,
          ...environment.toPayload()
        }
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
    _setProductsLoading(true);
    try {
      final values = await _queryProductsWithBootstrap();
      if (!_active) return;
      _productsLoaded = true;
      _products.clear();
      for (final product in values) {
        if (_requestedProductRefs!.contains(product.productRef)) {
          _products[product.productRef] = product;
        }
      }
      trace("products.loaded",
          "matched=${_products.length} requested=${_requestedProductRefs?.length ?? 0}");
      // 显式策略要求所有非可选商品就绪；旧页面保留部分商品可展示行为。
      final requiredRefs = sessionPolicy == null
          ? <String>[]
          : document.productRefs.where(
              (ref) => !sessionPolicy!.optionalProductRefs.contains(ref));
      if (environment.waitsForProducts && _products.isEmpty) {
        _fail("products_empty");
        return;
      }
      if (requiresStoreProducts &&
          (_products.isEmpty ||
              requiredRefs.any((ref) => !_products.containsKey(ref)))) {
        _fail("products_empty");
        return;
      }
      await _bootstrapIfPossible();
    } catch (error) {
      trace("products.failed", "error=${error.runtimeType}");
      _fail("products_query");
    } finally {
      _setProductsLoading(false);
    }
  }

  /// 商店查询与空商品桥消息并行，完整报价只能在 bootstrap 完成后交付。
  Future<List<PaywallStoreProduct>> _queryProductsWithBootstrap() async {
    if (!_supportsDeferredProducts) {
      return bridge.products(_requestedProductRefs!, storefrontGroup);
    }
    // 立即安装错误处理，查询即使同步抛错也不会产生无人接收的 Future。
    final query = Future<List<PaywallStoreProduct>>.sync(
            () => bridge.products(_requestedProductRefs!, storefrontGroup))
        .timeout(const Duration(seconds: 12));
    final results = await Future.wait<List<PaywallStoreProduct>>([
      _bootstrapIfPossible().then((_) => <PaywallStoreProduct>[]),
      query,
    ], eagerError: true);
    return results[1];
  }

  /// 桥与商品同时就绪才注入，重复 ready 不会重复查询或重置交易状态。
  Future<void> _bootstrapIfPossible() async {
    if (!_active ||
        !_bridgeReady ||
        (!_supportsDeferredProducts && !_productsLoaded) ||
        _productsDelivered) {
      return;
    }
    final updating = _bootstrapSent;
    if (updating && !_productsLoaded) return;
    _bootstrapSent = true;
    _productsDelivered = _productsLoaded;
    final visible =
        _requestedProductRefs!.where(_products.containsKey).map((ref) {
      final product = _products[ref]!;
      return {
        'productRef': ref,
        'displayPrice': product.displayPrice,
        'disclosure': product.disclosure,
        if (product.subscriptionPricing != null)
          'subscriptionPricing': product.subscriptionPricing!.toPayload(),
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
      'type': updating ? 'productsUpdated' : 'bootstrap',
      'capabilities': ['presentationState'],
      'bridgeVersion': 2,
      'sessionID': _sessionID,
      'custom': {
        ...?sessionPolicy?.custom,
        ...custom,
        ...environment.toPayload()
      },
      'allowsStoreActions': allowsStoreActions,
      'products': visible
    });
    await _sendPresentationState();
  }

  /// 首屏握手后同步真实可见状态，缓存页隐藏时由 H5 重置临时选择。
  Future<void> _sendPresentationState() async {
    if (!_active || !_bootstrapSent) return;
    await _send({
      'type': 'presentationState',
      'sessionID': _sessionID,
      'visible': _attached
    });
  }

  /// 新页面必须返回本次会话标识，旧页面继续允许无标识回执。
  bool _acceptsReceipt(Map<String, dynamic> event) {
    if (!_active || !_bootstrapSent) return false;
    if (event.containsKey('sessionID')) return event['sessionID'] == _sessionID;
    return !_expectsRenderReady;
  }

  /// 首屏就绪且正式挂载后通知页面，预加载不消耗动画。
  void _notifyPresentation() {
    if (!_active || !_attached || !ready.value) return;
    unawaited(_send({
      'type': 'presentationState',
      'sessionID': _sessionID,
      'presentationID': _presentationID,
      'visible': true
    }));
  }

  /// 收到适用协议的完成回执后才移除加载遮罩。
  void _finishRendering() {
    if (!_active || ready.value) return;
    _readyTimer?.cancel();
    trace("render.ready");
    ready.value = true;
    onRenderReady?.call();
    _notifyPresentation();
  }
}
