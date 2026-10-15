import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/paywall_runtime_controller.dart';
import '../widgets/paywall_node_widget.dart';
import '../widgets/paywall_purchase_bar.dart';

class PaywallRendererView extends GetView<PaywallRuntimeController> {
  const PaywallRendererView(
      {super.key, required this.sessionTag, required this.assetBuilder});
  final String sessionTag;
  final Widget? Function(String) assetBuilder;
  @override
  String? get tag => sessionTag;

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
                  assetBuilder: assetBuilder)),
      ]),
    ));
  }
}
