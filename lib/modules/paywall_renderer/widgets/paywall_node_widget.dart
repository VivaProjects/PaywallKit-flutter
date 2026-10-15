import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/paywall_runtime_controller.dart';
import '../models/paywall_node.dart';
import 'paywall_product_picker.dart';

class PaywallNodeWidget extends StatelessWidget {
  const PaywallNodeWidget(
      {super.key,
      required this.node,
      required this.controller,
      required this.assetBuilder});
  final PaywallNode node;
  final PaywallRuntimeController controller;
  final Widget? Function(String) assetBuilder;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    switch (node.type) {
      case PaywallNodeType.hero:
        return Semantics(
            label: snapshot.text(node.altKey),
            image: true,
            child: ExcludeSemantics(
                child: AspectRatio(
                    aspectRatio: node.aspectRatio,
                    child: assetBuilder(node.assetId!) ??
                        const Icon(Icons.image_outlined, size: 64))));
      case PaywallNodeType.heading:
        return Semantics(
            header: true,
            child: Text(snapshot.text(node.textKey),
                textAlign: node.alignment == 'center'
                    ? TextAlign.center
                    : TextAlign.start,
                style: switch (node.typography) {
                  'titleXL' => Theme.of(context).textTheme.headlineLarge,
                  'caption' => Theme.of(context).textTheme.bodySmall,
                  _ => Theme.of(context).textTheme.bodyLarge,
                }));
      case PaywallNodeType.benefitList:
        return _benefits();
      case PaywallNodeType.productPicker:
        return PaywallProductPicker(
            controller: controller, nodeId: node.nodeId);
      case PaywallNodeType.informationSection:
        if (node.collapsible) {
          return ExpansionTile(
              title: Text(snapshot.text(node.titleKey)),
              children: [Text(snapshot.text(node.bodyKey))]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(snapshot.text(node.titleKey)),
          Text(snapshot.text(node.bodyKey))
        ]);
      case PaywallNodeType.legalActions:
        return _legal();
      case PaywallNodeType.spacer:
        return SizedBox(
            height: snapshot.spacing[node.spacingToken]!.toDouble());
      case PaywallNodeType.closeButton:
        return _close();
      case PaywallNodeType.paywallScreen:
      case PaywallNodeType.purchaseBar:
        throw StateError('Root-only node in body');
    }
  }

  Widget _benefits() {
    final snapshot = controller.snapshot;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final text in snapshot.lists[node.itemsKey]!)
        Padding(
            padding: EdgeInsets.only(
                bottom: snapshot.spacing['itemGap']!.toDouble()),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.check_circle_outline),
              const SizedBox(width: 8),
              Expanded(child: Text(text))
            ])),
    ]);
  }

  Widget _legal() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Obx(() => TextButton(
            onPressed:
                controller.isPurchasing.value ? null : controller.restore,
            child: Text(controller.copy.restore))),
        TextButton(
            onPressed: () => controller.openLegal(PaywallLegalRoute.privacy),
            child: Text(controller.copy.privacy)),
        TextButton(
            onPressed: () => controller.openLegal(PaywallLegalRoute.terms),
            child: Text(controller.copy.terms)),
      ]);

  Widget _close() {
    if (!controller.allowsDismiss) return const SizedBox.shrink();
    return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Obx(() => IconButton(
            tooltip: controller.snapshot.text(node.labelKey),
            onPressed:
                controller.isPurchasing.value ? null : controller.dismiss,
            icon: const Icon(Icons.close))));
  }
}
