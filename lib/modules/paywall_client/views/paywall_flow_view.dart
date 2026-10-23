import 'package:flutter/material.dart';
import '../../web_paywall/views/web_paywall_surface.dart';
import '../controllers/paywall_flow_controller.dart';

/// 高层支付墙展示当前候选，失败时原生提供重试与关闭。
class PaywallFlowView extends StatefulWidget {
  const PaywallFlowView(
      {super.key,
      required this.controller,
      this.disposeController = true,
      this.isPresented = true});
  final PaywallFlowController controller;

  /// 默认随视图释放；外部持有者可关闭自动释放并在卸载后自行 dispose。
  final bool disposeController;
  final bool isPresented;
  @override
  State<PaywallFlowView> createState() => _PaywallFlowViewState();
}

class _PaywallFlowViewState extends State<PaywallFlowView> {
  PaywallFlowController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    if (widget.isPresented) {
      controller.start();
    } else {
      controller.load();
    }
  }

  /// 更换会话时终止旧实例并初始化新实例，禁止跨会话复用状态。
  @override
  void didUpdateWidget(covariant PaywallFlowView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, controller)) {
      if (widget.isPresented && !oldWidget.isPresented) controller.attach();
      if (!widget.isPresented) controller.detach();
      return;
    }
    if (oldWidget.disposeController) oldWidget.controller.dispose();
    if (widget.isPresented) {
      controller.start();
    } else {
      controller.load();
    }
  }

  @override
  void dispose() {
    if (widget.disposeController) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge(
          [controller.web, controller.failure, controller.ready]),
      builder: (context, child) {
        final web = controller.web.value;
        final error = controller.failure.value;
        return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop && widget.isPresented) controller.close();
            },
            child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Stack(fit: StackFit.expand, children: [
                  if (web != null)
                    ExcludeSemantics(
                        excluding:
                            !widget.isPresented || !controller.ready.value,
                        child: IgnorePointer(
                            ignoring:
                                !widget.isPresented || !controller.ready.value,
                            child: WebPaywallSurface(
                                key: ObjectKey(web),
                                controller: web,
                                visible: widget.isPresented &&
                                    controller.ready.value))),
                  if (!controller.ready.value)
                    ColoredBox(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: Center(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              if (error == null)
                                const CircularProgressIndicator(),
                              if (error != null) ...[
                                Text(controller.copy.unavailable),
                                TextButton(
                                    onPressed: controller.retry,
                                    child: Text(controller.copy.retry)),
                              ],
                              if (controller.allowsDismiss || error != null)
                                TextButton(
                                    onPressed: () =>
                                        controller.close(force: error != null),
                                    child: Text(
                                        MaterialLocalizations.of(context)
                                            .closeButtonLabel)),
                            ]))),
                ])));
      });
}
