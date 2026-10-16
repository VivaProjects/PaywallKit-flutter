import 'dart:async';
import 'package:flutter/material.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';
import '../controllers/paywall_flow_controller.dart';
import '../controllers/paywall_presentation_controller.dart';
import '../models/paywall_session_event.dart';
import '../services/paywall_preload.dart';
import '../views/paywall_flow_view.dart';
import '../views/paywall_sheet_view.dart';

/// Flutter 原生路由适配统一处理四种展示模式，接续必须等待旧路由完整退场。
class PaywallPresenter {
  PaywallPresenter({required this.controller, required this.navigator});
  final NavigatorState navigator;
  final PaywallPresentationController controller;
  static int _sequence = 0;

  /// 只按宿主授权配置接续，成功交易不进入 close 对应的下一点位。
  Future<PaywallSessionEventType?> present(
      {required String placement,
      required PaywallFlowController Function(String) create,
      bool waitsForReady = false,
      bool showBackButton = false,
      PaywallPreload? preload,
      Object cacheIdentity = 0,
      bool Function()? canPresent,
      bool followNextPlacement = true,
      void Function()? onDismiss,
      void Function()? onPresented}) async {
    final visited = <String>{};
    String? next = placement;
    PaywallSessionEventType? result;
    while (next != null && visited.add(next)) {
      if (!navigator.mounted || canPresent?.call() == false) return null;
      final token = controller.begin();
      if (token == null) return null;
      PaywallFlowController? flow;
      try {
        flow = create(next);
        final selected = await _prepare(
            flow, token, waitsForReady, preload, cacheIdentity, canPresent);
        if (selected == null) return null;
        result = await _show(selected, onPresented, showBackButton);
        next = followNextPlacement && result == PaywallSessionEventType.closed
            ? selected.nextPlacement
            : null;
      } finally {
        flow?.dispose();
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
      fresh.dispose();
      return null;
    }
    PaywallFlowController? flow = fresh;
    controller.current = flow;
    if (preload != null) {
      flow = preload.consume(fresh.client, fresh.placement,
          cacheIdentity: identity);
      flow?.bindPresentationCallbacks(fresh);
      fresh.dispose();
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
    if (!navigator.mounted ||
        controller.isDisposed ||
        controller.generation != token ||
        canPresent?.call() == false ||
        !flow.isUsable && flow.failure.value == null) {
      flow.dispose();
      return null;
    }
    return flow;
  }

  /// 等待状态变化而不是轮询；超时和失败都释放监听。
  Future<void> _awaitReady(PaywallFlowController flow) async {
    if (flow.ready.value) return;
    final done = Completer<void>();
    void changed() {
      if ((flow.ready.value || flow.failure.value != null) && !done.isCompleted)
        done.complete();
    }

    flow.ready.addListener(changed);
    flow.failure.addListener(changed);
    changed();
    try {
      await Future.any([done.future, controller.cancellation])
          .timeout(flow.timeout, onTimeout: () {});
    } finally {
      flow.ready.removeListener(changed);
      flow.failure.removeListener(changed);
    }
  }

  /// 使用局部路由承载展示方式，不查找或修改宿主的全局导航状态。
  PageRouteBuilder<PaywallSessionEventType> _createRoute(
      PaywallFlowController flow, bool showBackButton) {
    final tag = 'paywall-flow-${++_sequence}';
    final routeName = '/$tag';
    final sheet = flow.presentation == WebPaywallPresentation.halfSheet ||
        flow.presentation == WebPaywallPresentation.halfSheetLocked;
    return PageRouteBuilder<PaywallSessionEventType>(
        settings: RouteSettings(name: routeName),
        opaque: !sheet,
        fullscreenDialog:
            flow.presentation == WebPaywallPresentation.fullScreen,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) =>
            _buildPage(flow, sheet, showBackButton),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
                position: Tween<Offset>(
                        begin: flow.presentation == WebPaywallPresentation.push
                            ? const Offset(1, 0)
                            : const Offset(0, 1),
                        end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: animation, curve: Curves.easeOutCubic)),
                child: child));
  }

  /// 原生返回入口遵循会话权限，半屏继续使用自己的关闭交互。
  Widget _buildPage(
      PaywallFlowController flow, bool sheet, bool showBackButton) {
    final view = PaywallFlowView(controller: flow, disposeController: false);
    if (sheet) return PaywallSheetView(controller: flow, child: view);
    // H5 延伸到导航栏后方，返回控件仍由原生承载。
    return Scaffold(
        extendBodyBehindAppBar: showBackButton,
        appBar: showBackButton
            ? AppBar(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                leading: IconButton(
                    icon: const Icon(Icons.arrow_back), onPressed: flow.close))
            : null,
        body: view);
  }

  /// 等待完整退场后释放本次会话，外部路由不会被误关闭。
  Future<PaywallSessionEventType?> _show(PaywallFlowController flow,
      void Function()? onPresented, bool showBackButton) async {
    final route = _createRoute(flow, showBackButton);
    flow.onExit = (result) {
      if (route.isCurrent) {
        navigator.pop(result);
      } else if (route.isActive) {
        navigator.removeRoute(route);
      }
    };
    controller.commit();
    try {
      // removeRoute 在旧 Flutter 上不完成 push Future，completed 也必须能结束等待。
      final pushed = navigator.push(route);
      // 宿主观察回调异常不能中断路由回收或交易生命周期。
      try {
        onPresented?.call();
      } catch (_) {/* 隔离宿主观察者错误。 */}
      final result = await Future.any<PaywallSessionEventType?>([
        pushed,
        route.completed,
      ]);
      await route.completed;
      return result;
    } finally {
      flow.onExit = null;
      flow.dispose();
    }
  }
}
