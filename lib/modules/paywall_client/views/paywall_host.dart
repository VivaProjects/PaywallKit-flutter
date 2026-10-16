import 'package:flutter/material.dart';
import '../controllers/paywall_presentation_controller.dart';
import 'paywall_preparation_view.dart';

/// 宿主容器为就绪后展示提供隐藏 WebView 布局与可取消的准备遮罩。
class PaywallHost extends StatefulWidget {
  const PaywallHost(
      {super.key,
      required this.controller,
      required this.child,
      this.showLoading = true,
      this.canPresent = true,
      this.preparationIdentity = 0});
  final PaywallPresentationController controller;
  final Widget child;
  final bool showLoading;
  final bool canPresent;
  final Object preparationIdentity;
  @override
  State<PaywallHost> createState() => _PaywallHostState();
}

class _PaywallHostState extends State<PaywallHost> {
  PaywallPresentationController get controller => widget.controller;

  /// 宿主容器移除时取消尚未提交的准备，已经展示的路由仍归协调器管理。
  @override
  void dispose() {
    controller.cancelPreparation();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PaywallHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, controller))
      oldWidget.controller.cancelPreparation();
  }

  @override
  Widget build(BuildContext context) {
    final current = controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(current, controller))
        controller.updateConstraints(
            canPresent: widget.canPresent,
            identity: widget.preparationIdentity);
    });
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      PaywallPreparationView(preload: controller.preparation),
      if (widget.showLoading)
        ListenableBuilder(
            listenable: Listenable.merge([controller.preparing]),
            builder: (context, child) => controller.preparing.value
                ? ColoredBox(
                    color: Colors.black26,
                    child: Center(
                        child: Card(
                            child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const CircularProgressIndicator(),
                                      TextButton(
                                          onPressed:
                                              controller.cancelPreparation,
                                          child: Text(
                                              MaterialLocalizations.of(context)
                                                  .closeButtonLabel)),
                                    ])))))
                : const SizedBox.shrink()),
    ]);
  }
}
