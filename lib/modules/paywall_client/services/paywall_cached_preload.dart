import 'dart:async';
import '../../web_paywall/controllers/web_paywall_controller.dart';
import 'package:flutter/foundation.dart';
import '../controllers/paywall_flow_controller.dart';
import 'paywall_preload.dart';

/// 常驻入口后台预热完成后交给 Client 缓存，正式展示重建业务回调。
class PaywallCachedPreload {
  final preload = PaywallPreload();
  VoidCallback? _ready;
  int _generation = 0;
  PaywallFlowController? _flow;
  WebPaywallController? _parkingWeb;
  Completer<void>? _parkingCancellation;

  /// 配合 PaywallPreparationView 为后台网页提供真实布局空间。
  void start(PaywallFlowController flow) {
    cancel();
    _flow = flow;
    if (!flow.client.retainedPlacements.contains(flow.placement)) {
      flow.dispose();
      _flow = null;
      return;
    }
    flow.client.invalidatePage(flow.placement);
    final generation = ++_generation;
    _ready = () {
      final web = flow.web.value;
      if (!flow.ready.value || web == null || identical(web, _parkingWeb))
        return;
      _cancelParking();
      _parkingWeb = web;
      final cancelled = _parkingCancellation = Completer<void>();
      unawaited(_park(flow, web, generation, cancelled));
    };
    flow.ready.addListener(_ready!);
    preload.start(flow, cacheIdentity: flow.cacheIdentity);
  }

  /// 先完成成功版本记录，再把网页留给后续展示，不发送主动关闭事件。
  Future<void> _park(PaywallFlowController flow, WebPaywallController web,
      int generation, Completer<void> cancelled) async {
    try {
      final productsReady = await web.waitForProducts(
          cancelled: cancelled.future, timeout: flow.timeout);
      if (generation != _generation || !identical(flow.web.value, web)) return;
      if (productsReady) {
        await flow.parkInCache(
            () => generation == _generation && identical(_parkingWeb, web));
      }
      if (generation != _generation || !identical(_parkingWeb, web)) return;
      if (_ready != null) _flow?.ready.removeListener(_ready!);
      _ready = null;
      preload.cancel();
    } finally {
      if (!cancelled.isCompleted) cancelled.complete();
      if (identical(_parkingCancellation, cancelled)) {
        _parkingCancellation = null;
        _parkingWeb = null;
      }
    }
  }

  /// 新准备或取消时唤醒旧等待者，释放其计时器和监听。
  void _cancelParking() {
    final cancelled = _parkingCancellation;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    _parkingCancellation = null;
    _parkingWeb = null;
  }

  /// 宿主卸载隐藏视图后终止预热并释放监听。
  void dispose() {
    cancel();
    preload.dispose();
  }

  /// 权益身份改变或禁用预热时同步移除旧 Client 缓存。
  void cancel() {
    _generation++;
    _cancelParking();
    if (_ready != null) _flow?.ready.removeListener(_ready!);
    _ready = null;
    preload.cancel();
    final flow = _flow;
    if (flow != null) flow.client.invalidatePage(flow.placement);
    _flow = null;
  }
}
