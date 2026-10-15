import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../bindings/paywall_flow_binding.dart';
import '../controllers/paywall_flow_controller.dart';
import '../controllers/paywall_presentation_controller.dart';
import '../models/paywall_session_event.dart';
import '../services/paywall_preload.dart';
import '../views/paywall_flow_view.dart';
import '../views/paywall_sheet_view.dart';

/// GetX 路由适配统一处理四种展示模式，接续必须等待旧路由完整退场。
class PaywallPresenter {
  PaywallPresenter({required this.controller});
  final PaywallPresentationController controller;
  static int _sequence = 0;

  /// 只按宿主授权配置接续，成功交易不进入 close 对应的下一点位。
  Future<PaywallSessionEventType?> present(
      {required String placement,
      required PaywallFlowController Function(String) create,
      bool waitsForReady = false,
      PaywallPreload? preload,
      Object cacheIdentity = 0,
      bool Function()? canPresent,
      bool followNextPlacement = true,
      void Function()? onDismiss}) async {
    final visited = <String>{};
    String? next = placement;
    PaywallSessionEventType? result;
    while (next != null && visited.add(next)) {
      final token = controller.begin();
      if (token == null) return null;
      final flow = create(next);
      try {
        final selected = await _prepare(
            flow, token, waitsForReady, preload, cacheIdentity, canPresent);
        if (selected == null) return null;
        result = await _show(selected, token);
        next = followNextPlacement && result == PaywallSessionEventType.closed
            ? selected.nextPlacement
            : null;
      } finally {
        // 路由 completed 之前不会到这里，不能取消已经提交的后续请求。
        if (controller.generation == token) controller.finish();
      }
      onDismiss?.call();
      preload = null;
    }
    return result;
  }

  /// 隐藏准备必须获得首屏回执；无效预加载不会退回可见加载页面。
  Future<PaywallFlowController?> _prepare(
      PaywallFlowController fresh,
      int token,
      bool waits,
      PaywallPreload? preload,
      Object identity,
      bool Function()? canPresent) async {
    if (canPresent?.call() == false) {
      fresh.cancel();
      return null;
    }
    PaywallFlowController? flow = fresh;
    controller.current = flow;
    if (preload != null) {
      flow = preload.consume(fresh.client, fresh.placement,
          cacheIdentity: identity);
      flow?.bindPresentationCallbacks(fresh);
      fresh.cancel();
      if (flow == null) {
        preload.cancel();
        return null;
      }
      controller.current = flow;
    } else if (waits) {
      controller.preparation.start(flow, cacheIdentity: identity);
      await _awaitReady(flow);
      flow = controller.preparation
          .consume(flow.client, flow.placement, cacheIdentity: identity);
      if (flow == null) return null;
    } else {
      await Future.any([flow.load(), controller.cancellation]);
    }
    // 先让准备 WebView 从布局树退出，再把同一实例放入真实路由。
    await WidgetsBinding.instance.endOfFrame;
    if (controller.generation != token ||
        canPresent?.call() == false ||
        !flow.isUsable && flow.failure.value == null) {
      flow.cancel();
      return null;
    }
    return flow;
  }

  /// 等待状态变化而不是轮询；超时和失败都释放监听。
  Future<void> _awaitReady(PaywallFlowController flow) async {
    if (flow.ready.value) return;
    final done = Completer<void>();
    final ready = ever(flow.ready, (value) {
      if (value && !done.isCompleted) done.complete();
    });
    final failure = ever(flow.failure, (value) {
      if (value != null && !done.isCompleted) done.complete();
    });
    try {
      await Future.any([done.future, controller.cancellation])
          .timeout(flow.timeout, onTimeout: () {});
    } finally {
      ready.dispose();
      failure.dispose();
    }
  }

  /// 使用真实路由完成信号保留展示所有权，避免依靠延迟猜测退场结束。
  Future<PaywallSessionEventType?> _show(
      PaywallFlowController flow, int token) async {
    final tag = 'paywall-flow-${++_sequence}';
    final routeName = '/$tag';
    final sheet = flow.presentation == WebPaywallPresentation.halfSheet ||
        flow.presentation == WebPaywallPresentation.halfSheetLocked;
    Route<dynamic>? ownedRoute;
    flow.onExit = (result) {
      if (Get.currentRoute == routeName)
        Get.back(result: result);
      else if (ownedRoute?.isActive == true)
        ownedRoute!.navigator?.removeRoute(ownedRoute);
    };
    controller.commit();
    final result = Get.to<PaywallSessionEventType>(() {
      final view = PaywallFlowView(sessionTag: tag);
      return sheet
          ? PaywallSheetView(controller: flow, child: view)
          : Scaffold(body: view);
    },
        binding: PaywallFlowBinding(tag: tag, controller: flow),
        routeName: routeName,
        opaque: !sheet,
        preventDuplicates: false,
        popGesture: false,
        fullscreenDialog:
            flow.presentation == WebPaywallPresentation.fullScreen,
        transition: flow.presentation == WebPaywallPresentation.push
            ? Transition.rightToLeft
            : Transition.downToUp);
    ownedRoute = Get.rawRoute;
    final outcome = await result;
    if (ownedRoute is TransitionRoute) await ownedRoute.completed;
    return outcome;
  }
}
