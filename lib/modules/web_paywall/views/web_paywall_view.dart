import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../controllers/web_paywall_controller.dart';

/// 远程页面不可用时改用宿主已有的原生支付墙。
class WebPaywallView extends StatefulWidget {
  const WebPaywallView(
      {super.key,
      required this.controller,
      this.disposeController = true,
      required this.nativeFallback});
  final WebPaywallController controller;
  final WidgetBuilder nativeFallback;

  /// 默认随视图释放；外部持有者可关闭自动释放并在卸载后自行 dispose。
  final bool disposeController;
  @override
  State<WebPaywallView> createState() => _WebPaywallViewState();
}

class _WebPaywallViewState extends State<WebPaywallView> {
  WebPaywallController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.start();
  }

  /// 更换会话时终止旧实例并初始化新实例，禁止跨会话复用状态。
  @override
  void didUpdateWidget(covariant WebPaywallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, controller)) return;
    if (oldWidget.disposeController) oldWidget.controller.dispose();
    controller.start();
  }

  @override
  void dispose() {
    if (widget.disposeController) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([controller.failed, controller.ready]),
      builder: (context, child) => controller.failed.value
          ? widget.nativeFallback(context)
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
