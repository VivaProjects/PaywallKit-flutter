import 'package:flutter/material.dart';
import '../controllers/paywall_runtime_controller.dart';
import '../widgets/paywall_node_widget.dart';
import '../widgets/paywall_purchase_bar.dart';

class PaywallRendererView extends StatefulWidget {
  const PaywallRendererView(
      {super.key,
      required this.controller,
      this.disposeController = true,
      required this.assetBuilder});
  final PaywallRuntimeController controller;
  final Widget? Function(String) assetBuilder;

  /// 默认随视图释放；外部持有者可关闭自动释放并在卸载后自行 dispose。
  final bool disposeController;
  @override
  State<PaywallRendererView> createState() => _PaywallRendererViewState();
}

class _PaywallRendererViewState extends State<PaywallRendererView> {
  PaywallRuntimeController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.start();
  }

  /// 更换会话时终止旧实例并初始化新实例，禁止跨会话复用状态。
  @override
  void didUpdateWidget(covariant PaywallRendererView oldWidget) {
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
  Widget build(BuildContext context) {
    final accent = controller.snapshot.accent == 'interactiveGreen'
        ? Colors.green
        : Colors.blue;
    final theme = Theme.of(context);
    return Theme(
        data: theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(primary: accent)),
        child: PopScope(
          canPop: false,
          // Android 系统返回与关闭按钮共用宿主策略，强制入口不能绕过。
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) controller.dismiss();
          },
          child: Scaffold(
              body: _body(),
              bottomNavigationBar: SafeArea(
                  top: false,
                  child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                      child: SingleChildScrollView(
                          child: PaywallPurchaseBar(controller: controller))))),
        ));
  }

  Widget _body() {
    final snapshot = controller.snapshot;
    return SafeArea(
        child: SingleChildScrollView(
      padding: EdgeInsets.all(snapshot.spacing['pageX']!.toDouble()),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final node in snapshot.nodes)
          Padding(
              padding: EdgeInsets.only(
                  bottom: snapshot.spacing['section']!.toDouble()),
              child: PaywallNodeWidget(
                  key: ValueKey(node.nodeId),
                  node: node,
                  controller: controller,
                  assetBuilder: widget.assetBuilder)),
      ]),
    ));
  }
}
