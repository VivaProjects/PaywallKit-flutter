import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../controllers/web_paywall_controller.dart';

/// 远程页面不可用时改用宿主已有的原生支付墙。
class WebPaywallView extends GetView<WebPaywallController> {
  const WebPaywallView(
      {super.key, required this.sessionTag, required this.nativeFallback});
  final String sessionTag;
  final WidgetBuilder nativeFallback;
  @override
  String? get tag => sessionTag;

  @override
  Widget build(BuildContext context) => Obx(() => controller.failed.value
      ? nativeFallback(context)
      : PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) controller.close();
          },
          child: Scaffold(
              body: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeSemantics(
                excluding: !controller.ready.value,
                child: IgnorePointer(
                  ignoring: !controller.ready.value,
                  child: WebViewWidget(controller: controller.webView),
                ),
              ),
              if (!controller.ready.value)
                ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Center(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      if (controller.allowsDismiss) ...[
                        const SizedBox(height: 20),
                        TextButton(
                          onPressed: controller.close,
                          child: Text(MaterialLocalizations.of(context)
                              .closeButtonLabel),
                        ),
                      ],
                    ],
                  )),
                ),
            ],
          )),
        ));
}
