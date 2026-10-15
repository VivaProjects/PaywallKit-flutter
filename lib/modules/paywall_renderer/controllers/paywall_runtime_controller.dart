import 'package:get/get.dart';
import '../models/paywall_event.dart';
import '../models/paywall_runtime_copy.dart';
import '../models/paywall_snapshot.dart';
import '../models/paywall_store_product.dart';
import '../services/paywall_purchase_bridge.dart';

enum PaywallLegalRoute { privacy, terms }

class PaywallRuntimeController extends GetxController {
  PaywallRuntimeController(
      {required this.snapshot,
      required this.bridge,
      required this.allowsDismiss,
      required this.onDismiss,
      required this.openLegal,
      required this.track,
      this.copy = const PaywallRuntimeCopy()});
  final PaywallSnapshot snapshot;
  final PaywallPurchaseBridge bridge;
  final bool allowsDismiss;
  final void Function() onDismiss;
  final void Function(PaywallLegalRoute) openLegal;
  final void Function(PaywallEvent) track;
  final PaywallRuntimeCopy copy;
  final products = <PaywallStoreProduct>[].obs;
  final selectedRef = RxnString();
  final isLoading = false.obs;
  final isPurchasing = false.obs;
  final loadFailed = false.obs;
  final message = RxnString();
  bool _closed = false;

  @override
  void onReady() {
    super.onReady();
    _emit(PaywallEventName.paywallImpression);
    load();
  }

  PaywallStoreProduct? get selectedProduct =>
      products.firstWhereOrNull((v) => v.productRef == selectedRef.value);

  /// 只刷新冻结的商品引用，不采纳返回值中额外的商品。
  Future<void> load() async {
    if (_closed || isLoading.value || isPurchasing.value) return;
    isLoading.value = true;
    message.value = null;
    try {
      final fetched =
          await bridge.products(snapshot.productRefs, snapshot.storefrontGroup);
      if (_closed) return;
      _validateProducts(fetched);
      products.assignAll(snapshot.productRefs
          .expand((ref) => fetched.where((v) => v.productRef == ref)));
      if (!products.any((v) => v.productRef == selectedRef.value)) {
        final picker = snapshot.nodes.firstWhere((v) => v.catalogKey != null);
        final preferred =
            picker.selection == 'recommended' ? snapshot.recommendedRef : null;
        selectedRef.value = products
                .firstWhereOrNull((v) => v.productRef == preferred)
                ?.productRef ??
            products.first.productRef;
      }
      loadFailed.value = false;
    } catch (_) {
      if (_closed) return;
      products.clear();
      selectedRef.value = null;
      loadFailed.value = true;
      message.value = copy.unavailable;
      _emit(PaywallEventName.paywallRenderError,
          {'errorCategory': 'product_load'});
    } finally {
      if (!_closed) isLoading.value = false;
    }
  }

  /// 重复、越界或缺少商店披露的商品都禁止展示为可购买项。
  void _validateProducts(List<PaywallStoreProduct> fetched) {
    if (fetched.isEmpty ||
        fetched.map((v) => v.productRef).toSet().length != fetched.length ||
        fetched.map((v) => v.storeProductId).toSet().length != fetched.length ||
        fetched.any((v) =>
            !snapshot.productRefs.contains(v.productRef) ||
            v.storeProductId.isEmpty ||
            v.title.isEmpty ||
            v.displayPrice.isEmpty ||
            v.disclosure.isEmpty)) {
      throw const FormatException('invalid_store_products');
    }
  }

  /// 忙碌时冻结选择，节点只能引用当前实际加载的商品。
  void select(PaywallStoreProduct product, String nodeId) {
    if (_closed ||
        isPurchasing.value ||
        isLoading.value ||
        !products.contains(product)) return;
    selectedRef.value = product.productRef;
    _emit(PaywallEventName.paywallProductSelected, {
      'productRef': product.productRef,
      'nodeId': nodeId,
      'selectionSource': 'user'
    });
  }

  /// 同步设置忙碌锁，避免重复点击引起并行支付。
  Future<void> purchase() async {
    final product = selectedProduct;
    if (_closed || isPurchasing.value || isLoading.value || product == null)
      return;
    isPurchasing.value = true;
    _emit(PaywallEventName.paywallPurchaseStarted, {
      'productRef': product.productRef,
      'storeProductId': product.storeProductId
    });
    await _transaction(product);
  }

  /// 恢复入口在商品失败时仍然可用，并与购买共用互斥锁。
  Future<void> restore() async {
    if (_closed || isPurchasing.value) return;
    isPurchasing.value = true;
    await _transaction(null);
  }

  /// 路由销毁后不回写 Rx；商店权益更新仍由宿主完成。
  Future<void> _transaction(PaywallStoreProduct? product) async {
    message.value = null;
    final event = product == null
        ? PaywallEventName.paywallRestoreResult
        : PaywallEventName.paywallPurchaseResult;
    try {
      final result = product == null
          ? await bridge.restore()
          : await bridge.purchase(product);
      // 即使关闭页面，交易结果也需要携带原快照版本归因。
      _emit(event,
          {'result': result.name, 'productRef': product?.productRef ?? ''});
      if (_closed) return;
      message.value = switch (result) {
        PaywallPurchaseResult.succeeded => copy.succeeded,
        PaywallPurchaseResult.pending => copy.pending,
        PaywallPurchaseResult.noEntitlement => copy.noEntitlement,
        PaywallPurchaseResult.cancelled => null,
      };
    } catch (_) {
      _emit(event, {'result': 'failed', 'storeErrorCategory': 'bridge_error'});
      if (!_closed) message.value = copy.failed;
    } finally {
      if (!_closed) isPurchasing.value = false;
    }
  }

  /// 强制入口的关闭策略由宿主决定，不读取远端关闭权限。
  void dismiss() {
    if (_closed || !allowsDismiss || isPurchasing.value) return;
    _emit(PaywallEventName.paywallDismissed, {'reason': 'userClose'});
    onDismiss();
  }

  /// 固定事件名与版本维度，分析失败不应中断购买。
  void _emit(PaywallEventName name, [Map<String, Object> fields = const {}]) {
    try {
      track(PaywallEvent(name, {
        'documentId': snapshot.documentId,
        'revision': snapshot.revision,
        'placement': snapshot.placement,
        'variant': snapshot.variant,
        'rendererVersion': 1,
        ...snapshot.assignment,
        ...fields
      }));
    } catch (_) {/* 宿主分析适配层负责日志与重试。 */}
  }

  @override
  void onClose() {
    _closed = true;
    super.onClose();
  }
}
