import 'dart:async';
import 'package:flutter/foundation.dart';
import '../controllers/paywall_flow_controller.dart';
import 'paywall_client.dart';

/// 单次可消费的预渲染句柄；必须配合隐藏准备视图提供真实布局空间。
class PaywallPreload {
  final page = ValueNotifier<PaywallFlowController?>(null);
  Object? _identity;
  bool _consumed = false;
  Timer? _deadline;
  VoidCallback? _readyListener, _failureListener;
  PaywallFlowController? _observed;
  bool _disposed = false;
  bool get isReady =>
      !_consumed &&
      page.value?.isUsable == true &&
      page.value?.ready.value == true;

  /// 创建后台会话，十二秒内未收到首屏回执就取消整个准备流程。
  void start(PaywallFlowController controller, {Object cacheIdentity = 0}) {
    if (_disposed) throw StateError('PaywallPreload is disposed');
    cancel();
    _consumed = false;
    _identity = cacheIdentity;
    page.value = controller;
    _observed = controller;
    _readyListener = () {
      if (controller.ready.value) _deadline?.cancel();
    };
    _failureListener = () {
      // 在通知栈退出后取消，避免释放正在通知的状态对象。
      if (controller.failure.value != null)
        scheduleMicrotask(() {
          if (identical(_observed, controller)) cancel();
        });
    };
    controller.ready.addListener(_readyListener!);
    controller.failure.addListener(_failureListener!);
    _deadline = Timer(controller.timeout, cancel);
    unawaited(controller.load());
  }

  /// 只有同一 Client、入口和资格身份可接管，交接后句柄不再持有页面。
  PaywallFlowController? consume(PaywallClient client, String placement,
      {Object cacheIdentity = 0}) {
    final value = page.value;
    if (!isReady ||
        value == null ||
        !identical(value.client, client) ||
        value.placement != placement ||
        _identity != cacheIdentity ||
        client.isPlacementDisabled(placement)) return null;
    _consumed = true;
    _releaseObservers();
    page.value = null;
    return value;
  }

  /// 取消不会销毁已交给展示路由的实例。
  void cancel() {
    _releaseObservers();
    final flow = page.value;
    page.value = null;
    flow?.dispose();
  }

  /// 宿主卸载准备视图后释放句柄，已消费的会话仍归展示方所有。
  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
    page.dispose();
  }

  /// 所有观察者和截止时间都有明确所有者，页面就绪后不会继续计时。
  void _releaseObservers() {
    _deadline?.cancel();
    _deadline = null;
    final flow = _observed;
    if (flow != null) {
      if (_readyListener != null) flow.ready.removeListener(_readyListener!);
      if (_failureListener != null)
        flow.failure.removeListener(_failureListener!);
    }
    _observed = null;
    _readyListener = null;
    _failureListener = null;
  }
}
