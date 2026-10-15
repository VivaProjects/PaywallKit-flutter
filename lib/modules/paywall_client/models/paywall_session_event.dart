import '../../paywall_renderer/services/paywall_purchase_bridge.dart';
import 'paywall_placement.dart';
import 'paywall_failure.dart';

enum PaywallSessionEventType {
  ready,
  resolved,
  closed,
  retrying,
  purchaseFinished,
  restoreFinished,
  actionFailed,
  failed
}

/// 业务事件明确区分交易成功、主动关闭与渲染失败。
class PaywallSessionEvent {
  const PaywallSessionEvent(this.type,
      {this.placement,
      this.productRefs = const [],
      this.productRef,
      this.result,
      this.failure,
      this.action});
  final PaywallSessionEventType type;
  final PaywallPlacement? placement;
  final List<String> productRefs;
  final String? productRef;
  final PaywallPurchaseResult? result;
  final PaywallFailure? failure;
  final String? action;
}
