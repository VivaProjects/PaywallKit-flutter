import 'dart:async';
import 'package:flutter/services.dart';
import '../../../paywall_renderer/models/paywall_store_product.dart';
import '../../../paywall_renderer/services/paywall_purchase_bridge.dart';
import 'google_play_quote.dart';
import 'paywall_google_play_purchase.dart';

/// Android 默认商店桥：商品、优惠和购买由 SDK 连接，宿主只验证交易与发放权益。
class PaywallGooglePlayPurchaseBridge implements PaywallPurchaseBridge {
  /// 验证回调须检查真实权益，不能仅凭购买回调或 token 非空返回 true。
  PaywallGooglePlayPurchaseBridge({required this.verifyPurchase});
  final Future<bool> Function(PaywallGooglePlayPurchase purchase)
      verifyPurchase;
  static const _channel = MethodChannel('native_paywall/resources');
  static int _nextOwner = 0;
  final String _owner =
      'play-${DateTime.now().microsecondsSinceEpoch}-${_nextOwner++}';
  final Expando<GooglePlayQuote> _quotes = Expando<GooglePlayQuote>();
  bool _disposed = false, _transactionActive = false;

  /// 根据绑定的商品 ID 查询，优惠数据随商品返回，无需 custom 优惠开关。
  @override
  Future<List<PaywallStoreProduct>> products(
      List<String> references, String storefrontGroup) async {
    if (references.isEmpty ||
        references.length > 100 ||
        references.toSet().length != references.length ||
        references.any((id) => id.isEmpty)) {
      throw const FormatException('Invalid product references');
    }
    final values = await _invoke<List<dynamic>>(
        'googlePlayProducts', {'productRefs': references});
    final quotes = [
      for (final value in values ?? [])
        GooglePlayQuote.fromPayload(Map<String, dynamic>.from(value as Map))
    ];
    if (quotes.length != references.length ||
        quotes.map((q) => q.product.productRef).toSet().length !=
            references.length ||
        quotes.any((q) => !references.contains(q.product.productRef))) {
      throw const FormatException(
          'Store product response does not match requested IDs');
    }
    // 使用对象身份绑定报价，后续同 ID 查询不能偷偷替换旧页面正在展示的方案。
    for (final quote in quotes) {
      _quotes[quote.product] = quote;
    }
    return [
      for (final ref in references)
        quotes.singleWhere((q) => q.product.productRef == ref).product
    ];
  }

  /// 原生会重新核对报价，随后使用展示时选定的 offerToken 发起购买。
  @override
  Future<PaywallPurchaseResult> purchase(PaywallStoreProduct product) async {
    _beginTransaction();
    try {
      final quote = _quotes[product];
      if (quote == null)
        throw StateError('Product was not queried by this bridge');
      final value = await _invoke<Map<dynamic, dynamic>>('googlePlayPurchase', {
        'quoteId': quote.quoteId,
        'offerToken': quote.offerToken,
      });
      if (value?['cancelled'] == true) return PaywallPurchaseResult.cancelled;
      final receipt = PaywallGooglePlayPurchase.fromPayload(
          Map<String, dynamic>.from(value!));
      if (!receipt.productIds.contains(product.storeProductId))
        throw StateError('Unexpected purchased product');
      if (receipt.pending) return PaywallPurchaseResult.pending;
      return await _verifyAndAcknowledge(receipt)
          ? PaywallPurchaseResult.succeeded
          : PaywallPurchaseResult.noEntitlement;
    } finally {
      _transactionActive = false;
    }
  }

  /// 恢复或重新进入前可调用此方法处理延迟完成的购买，验单前不会报告成功。
  @override
  Future<PaywallPurchaseResult> restore() async {
    _beginTransaction();
    try {
      final values = await _invoke<List<dynamic>>('googlePlayRestore');
      var granted = false, pending = false;
      for (final value in values ?? []) {
        final receipt = PaywallGooglePlayPurchase.fromPayload(
            Map<String, dynamic>.from(value as Map));
        if (receipt.pending) {
          pending = true;
          continue;
        }
        if (await _verifyAndAcknowledge(receipt)) granted = true;
      }
      return granted
          ? PaywallPurchaseResult.succeeded
          : pending
              ? PaywallPurchaseResult.pending
              : PaywallPurchaseResult.noEntitlement;
    } finally {
      _transactionActive = false;
    }
  }

  /// 宿主验单并发放权益后再确认交易；失败和 pending 均不 acknowledge。
  Future<bool> _verifyAndAcknowledge(PaywallGooglePlayPurchase purchase) async {
    _checkActive();
    final accepted = await verifyPurchase(purchase);
    _checkActive();
    if (!accepted) return false;
    if (!purchase.acknowledged) {
      await _invoke<void>(
          'googlePlayAcknowledge', {'purchaseToken': purchase.purchaseToken});
    }
    return true;
  }

  /// 购买和恢复互斥，避免同一个交易重复验证和完成。
  void _beginTransaction() {
    _checkActive();
    if (_transactionActive)
      throw StateError('A store transaction is already active');
    _transactionActive = true;
  }

  /// 释放后所有迟到结果失效，不能继续操作页面或购买。
  void _checkActive() {
    if (_disposed) throw StateError('Google Play bridge disposed');
  }

  /// 通道请求绑定实例所有者，不借助宿主全局服务定位器。
  Future<T?> _invoke<T>(String method,
      [Map<String, dynamic> arguments = const {}]) async {
    _checkActive();
    final value =
        await _channel.invokeMethod<T>(method, {'owner': _owner, ...arguments});
    _checkActive();
    return value;
  }

  /// 由创建该桥的宿主释放；应晚于使用它的支付墙会话销毁。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod<void>('googlePlayDispose', {'owner': _owner});
  }
}
