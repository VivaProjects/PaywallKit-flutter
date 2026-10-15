import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/paywall_preload.dart';

/// 隐藏预渲染保留真实布局尺寸，禁止触摸和辅助功能访问。
class PaywallPreparationView extends StatelessWidget {
  const PaywallPreparationView({super.key, required this.preload});
  final PaywallPreload preload;
  @override
  Widget build(BuildContext context) => Obx(() {
        final flow = preload.page.value;
        final web = flow?.web.value;
        if (web == null) return const SizedBox.shrink();
        return ExcludeSemantics(
            child: IgnorePointer(
                child: Opacity(
                    opacity: 0,
                    child: WebViewWidget(
                        key: ObjectKey(web), controller: web.webView))));
      });
}
