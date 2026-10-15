import 'dart:async';
import 'package:get/get.dart';
import '../controllers/paywall_flow_controller.dart';
import 'paywall_client.dart';

/// 单次可消费的预渲染句柄；必须配合隐藏准备视图提供真实布局空间。
class PaywallPreload {
  final page = Rxn<PaywallFlowController>();
  Object? _identity;
  bool _consumed = false;
  Timer? _deadline;
  Worker? _readyWorker, _failureWorker;
  bool get isReady =>
      !_consumed &&
      page.value?.isUsable == true &&
      page.value?.ready.value == true;

  /// 创建后台会话，十二秒内未收到首屏回执就取消整个准备流程。
  void start(PaywallFlowController controller, {Object cacheIdentity = 0}) {
    cancel();
    _consumed = false;
    _identity = cacheIdentity;
    page.value = controller;
    _readyWorker = ever(controller.ready, (value) {
      if (value) _deadline?.cancel();
    });
    _failureWorker = ever(controller.failure, (value) {
      if (value != null) cancel();
    });
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
    page.value?.cancel();
    page.value = null;
  }

  /// 所有观察者和截止时间都有明确所有者，页面就绪后不会继续计时。
  void _releaseObservers() {
    _deadline?.cancel();
    _deadline = null;
    _readyWorker?.dispose();
    _readyWorker = null;
    _failureWorker?.dispose();
    _failureWorker = null;
  }
}
