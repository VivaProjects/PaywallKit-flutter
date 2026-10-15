import 'dart:async';
import 'package:get/get.dart';
import '../controllers/paywall_flow_controller.dart';
import 'paywall_preload.dart';

/// 常驻入口后台预热完成后交给 Client 缓存，正式展示重建业务回调。
class PaywallCachedPreload {
  final preload = PaywallPreload();
  Worker? _ready;
  int _generation = 0;
  PaywallFlowController? _flow;

  /// 配合 PaywallPreparationView 为后台网页提供真实布局空间。
  void start(PaywallFlowController flow) {
    cancel();
    _flow = flow;
    if (!flow.client.retainedPlacements.contains(flow.placement)) return;
    flow.client.invalidatePage(flow.placement);
    final generation = ++_generation;
    _ready = ever(flow.ready, (ready) {
      if (ready) unawaited(_park(flow, generation));
    });
    preload.start(flow, cacheIdentity: flow.cacheIdentity);
  }

  /// 先完成成功版本记录，再把网页留给后续展示，不发送主动关闭事件。
  Future<void> _park(PaywallFlowController flow, int generation) async {
    await flow.parkInCache(() => generation == _generation);
    if (generation != _generation) return;
    _ready?.dispose();
    _ready = null;
    preload.cancel();
  }

  /// 权益身份改变或禁用预热时同步移除旧 Client 缓存。
  void cancel() {
    _generation++;
    _ready?.dispose();
    _ready = null;
    preload.cancel();
    final flow = _flow;
    if (flow != null) flow.client.invalidatePage(flow.placement);
    _flow = null;
  }
}
