import 'dart:async';
import 'package:flutter/foundation.dart';
import '../controllers/paywall_flow_controller.dart';
import 'paywall_preload.dart';

/// 常驻入口后台预热完成后交给 Client 缓存，正式展示重建业务回调。
class PaywallCachedPreload {
  final preload = PaywallPreload();
  VoidCallback? _ready;
  int _generation = 0;
  PaywallFlowController? _flow;

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
      if (flow.ready.value) unawaited(_park(flow, generation));
    };
    flow.ready.addListener(_ready!);
    preload.start(flow, cacheIdentity: flow.cacheIdentity);
  }

  /// 先完成成功版本记录，再把网页留给后续展示，不发送主动关闭事件。
  Future<void> _park(PaywallFlowController flow, int generation) async {
    // JS 首屏回执可能早于 bootstrap 调用返回；等待商品门禁解除再接管。
    final deadline = DateTime.now().add(flow.timeout);
    while (generation == _generation &&
        flow.isUsable &&
        flow.web.value?.awaitingProducts == true &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (generation != _generation) return;
    await flow.parkInCache(() => generation == _generation);
    if (generation != _generation) return;
    if (_ready != null) _flow?.ready.removeListener(_ready!);
    _ready = null;
    preload.cancel();
  }

  /// 宿主卸载隐藏视图后终止预热并释放监听。
  void dispose() {
    cancel();
    preload.dispose();
  }

  /// 权益身份改变或禁用预热时同步移除旧 Client 缓存。
  void cancel() {
    _generation++;
    if (_ready != null) _flow?.ready.removeListener(_ready!);
    _ready = null;
    preload.cancel();
    final flow = _flow;
    if (flow != null) flow.client.invalidatePage(flow.placement);
    _flow = null;
  }
}
