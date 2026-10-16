import 'dart:async';
import 'package:flutter/foundation.dart';
import 'paywall_flow_controller.dart';
import '../services/paywall_preload.dart';

/// 宿主级展示锁保留到路由退场完成，避免首墙关闭误取消已提交的第二墙。
class PaywallPresentationController {
  bool _disposed = false;
  bool get isDisposed => _disposed;
  final preparing = ValueNotifier(false);
  final preparation = PaywallPreload();
  bool committed = false;
  bool active = false;
  int generation = 0;
  Completer<void> _cancellation = Completer<void>();
  Future<void> get cancellation => _cancellation.future;
  Object? _preparationIdentity;
  PaywallFlowController? current;

  /// 宿主资格或身份变化立即取消未提交准备，不影响已经展示的路由。
  void updateConstraints({required bool canPresent, required Object identity}) {
    if (_disposed) return;
    if (!committed &&
        active &&
        (!canPresent ||
            _preparationIdentity != null && _preparationIdentity != identity))
      cancelPreparation();
    _preparationIdentity = identity;
  }

  /// 同一宿主同时只接受一个展示请求，后续入口等待完整退场。
  int? begin() {
    if (_disposed || active) return null;
    _cancellation = Completer<void>();
    active = true;
    preparing.value = true;
    return ++generation;
  }

  /// 未提交的准备可取消，已经提交的展示由当前路由负责退场。
  void cancelPreparation() {
    if (_disposed || committed) return;
    generation++;
    if (!_cancellation.isCompleted) _cancellation.complete();
    preparation.cancel();
    current?.dispose();
    current = null;
    active = false;
    preparing.value = false;
  }

  /// 展示提交后关闭准备层，展示锁仍保留。
  void commit() {
    if (_disposed) return;
    committed = true;
    preparing.value = false;
  }

  /// 只有路由动画结束后才释放展示锁并允许下一点位进入。
  void finish() {
    if (_disposed) return;
    preparation.cancel();
    current = null;
    committed = false;
    active = false;
    preparing.value = false;
  }

  /// 宿主销毁后停止准备或关闭已提交路由，路由自身负责释放展示实例。
  void dispose() {
    if (_disposed) return;
    if (!committed) cancelPreparation();
    _disposed = true;
    if (committed) current?.close(force: true);
    current = null;
    active = false;
    committed = false;
    preparation.dispose();
    preparing.dispose();
  }
}
