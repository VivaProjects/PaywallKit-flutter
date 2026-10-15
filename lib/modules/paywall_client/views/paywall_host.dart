import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/paywall_presentation_controller.dart';
import 'paywall_preparation_view.dart';

/// 宿主容器为就绪后展示提供隐藏 WebView 布局与可取消的准备遮罩。
class PaywallHost extends StatelessWidget {
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
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) =>
        controller.updateConstraints(
            canPresent: canPresent, identity: preparationIdentity));
    return Stack(fit: StackFit.expand, children: [
      child,
      PaywallPreparationView(preload: controller.preparation),
      if (showLoading)
        Obx(() => controller.preparing.value
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
                                      onPressed: controller.cancelPreparation,
                                      child: Text(
                                          MaterialLocalizations.of(context)
                                              .closeButtonLabel)),
                                ])))))
            : const SizedBox.shrink()),
    ]);
  }
}
