import 'package:flutter/material.dart';
import '../controllers/paywall_runtime_controller.dart';
import '../models/paywall_store_product.dart';

class PaywallProductPicker extends StatelessWidget {
  const PaywallProductPicker(
      {super.key, required this.controller, required this.nodeId});
  final PaywallRuntimeController controller;
  final String nodeId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([
        controller.products,
        controller.selectedRef,
        controller.isLoading,
        controller.loadFailed,
        controller.isPurchasing
      ]),
      builder: (context, child) {
        if (controller.isLoading.value)
          return Semantics(
              label: controller.copy.loading,
              child: const Center(child: CircularProgressIndicator()));
        if (controller.loadFailed.value) {
          return Column(children: [
            Text(controller.copy.unavailable),
            TextButton(
                onPressed: controller.load, child: Text(controller.copy.retry))
          ]);
        }
        return Column(children: [
          for (final product in controller.products.value)
            _product(context, product)
        ]);
      });

  Widget _product(BuildContext context, PaywallStoreProduct product) {
    final selected = controller.selectedRef.value == product.productRef;
    return Semantics(
        selected: selected,
        child: Card(
          shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(controller.snapshot.cardRadius),
              side: BorderSide(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor)),
          child: InkWell(
            onTap: controller.isPurchasing.value
                ? null
                : () => controller.select(product, nodeId),
            borderRadius: BorderRadius.circular(controller.snapshot.cardRadius),
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                    width: double.infinity,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(selected
                                ? Icons.check_circle
                                : Icons.circle_outlined),
                            const SizedBox(width: 8),
                            Expanded(child: Text(product.title))
                          ]),
                          Text(product.displayPrice),
                          Text(product.disclosure),
                          if (product.productRef ==
                              controller.snapshot.recommendedRef)
                            Text(controller.copy.recommended),
                        ]))),
          ),
        ));
  }
}
