import 'package:flutter/material.dart';
import '../controllers/paywall_runtime_controller.dart';

class PaywallPurchaseBar extends StatelessWidget {
  const PaywallPurchaseBar({super.key, required this.controller});
  final PaywallRuntimeController controller;

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(16),
      child: ListenableBuilder(
          listenable: Listenable.merge([
            controller.products,
            controller.selectedRef,
            controller.message,
            controller.isPurchasing,
            controller.isLoading
          ]),
          builder: (context, child) {
            final product = controller.selectedProduct;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              if (product != null) ...[
                Text(product.displayPrice),
                Text(product.disclosure)
              ],
              if (controller.message.value != null)
                Semantics(
                    liveRegion: true, child: Text(controller.message.value!)),
              const SizedBox(height: 8),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: product == null ||
                            controller.isPurchasing.value ||
                            controller.isLoading.value
                        ? null
                        : controller.purchase,
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            children: [
                              if (controller.isPurchasing.value)
                                const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                              Text(controller.snapshot.text(
                                  controller.snapshot.bottomBar.titleKey)),
                            ])),
                  )),
            ]);
          }));
}
