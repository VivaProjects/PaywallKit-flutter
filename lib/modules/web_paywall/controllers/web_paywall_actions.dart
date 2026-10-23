part of 'web_paywall_controller.dart';

/// 交易与展示分离，所有动作仍受当前会话生命周期约束。
extension WebPaywallActions on WebPaywallController {
  /// 只允许已展示且未处理交易的会话调用宿主购买。
  Future<void> _purchase(Object? ref) async {
    // 缓存报价未确认时结束网页等待，不让旧报价进入宿主交易。
    if (_active && _attached && _productsLoading) {
      await _send({'type': 'purchaseResult', 'result': 'failed'});
      return;
    }
    if (!allowsStoreActions ||
        !_attached ||
        !_active ||
        !ready.value ||
        _busy ||
        ref is! String ||
        !_products.containsKey(ref) ||
        (sessionPolicy != null &&
            !sessionPolicy!.purchasableProductRefs.contains(ref))) {
      await _send({'type': 'purchaseResult', 'result': 'failed'});
      return;
    }
    trace("action.start", "type=purchase");
    _busy = true;
    try {
      final result = await bridge.purchase(_products[ref]!);
      trace('action.result', 'type=purchase result=${result.name}');
      await _send({'type': 'purchaseResult', 'result': result.name});
      _notifyResult(() => onPurchaseResult?.call(ref, result));
    } catch (_) {
      trace('action.result', 'type=purchase result=failed');
      await _send({'type': 'purchaseResult', 'result': 'failed'});
      _notifyResult(() => onActionFailure?.call('purchase'));
    } finally {
      _busy = false;
    }
  }

  /// 恢复与购买互斥，结果只投递给仍存活的会话。
  Future<void> _restore() async {
    // 避免恢复交易与报价变化触发的页面重建并发。
    if (_active && _attached && _productsLoading) {
      await _send({'type': 'restoreResult', 'result': 'failed'});
      return;
    }
    if (!_attached || !_active || !ready.value || _busy) return;
    if (!allowsStoreActions) {
      await _send({'type': 'restoreResult', 'result': 'failed'});
      return;
    }
    trace("action.start", "type=restore");
    _busy = true;
    try {
      final result = await bridge.restore();
      trace('action.result', 'type=restore result=${result.name}');
      await _send({'type': 'restoreResult', 'result': result.name});
      _notifyResult(() => onRestoreResult?.call(result));
    } catch (_) {
      trace('action.result', 'type=restore result=failed');
      await _send({'type': 'restoreResult', 'result': 'failed'});
      _notifyResult(() => onActionFailure?.call('restore'));
    } finally {
      _busy = false;
    }
  }

  /// 宿主业务回调异常不能把已经完成的真实交易改报为失败。
  void _notifyResult(void Function() callback) {
    if (!_active || !_attached) return;
    try {
      callback();
    } catch (_) {
      trace('action.callback_failed');
    }
  }
}
