import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../controllers/paywall_flow_controller.dart';

/// 高层支付墙展示当前候选，失败时原生提供重试与关闭。
class PaywallFlowView extends GetView<PaywallFlowController> {
  const PaywallFlowView({super.key, required this.sessionTag});
  final String sessionTag;
  @override
  String? get tag => sessionTag;

  @override
  Widget build(BuildContext context) => Obx(() {
        final web = controller.web.value;
        final error = controller.failure.value;
        return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) controller.close();
            },
            child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Stack(fit: StackFit.expand, children: [
                  if (web != null)
                    ExcludeSemantics(
                        excluding: !controller.ready.value,
                        child: IgnorePointer(
                            ignoring: !controller.ready.value,
                            child: WebViewWidget(
                                key: ObjectKey(web), controller: web.webView))),
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
