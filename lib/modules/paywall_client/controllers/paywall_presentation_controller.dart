import 'dart:async';
import 'package:get/get.dart';
import 'paywall_flow_controller.dart';
import '../services/paywall_preload.dart';

/// 宿主级展示锁保留到路由退场完成，避免首墙关闭误取消已提交的第二墙。
class PaywallPresentationController extends GetxController {
  final preparing = false.obs;
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
    if (!committed &&
        active &&
        (!canPresent ||
            _preparationIdentity != null && _preparationIdentity != identity))
      cancelPreparation();
    _preparationIdentity = identity;
  }

  /// 同一宿主同时只接受一个展示请求，后续入口等待完整退场。
  int? begin() {
    if (active) return null;
    _cancellation = Completer<void>();
    active = true;
    preparing.value = true;
    return ++generation;
  }

  /// 未提交的准备可取消，已经提交的展示由当前路由负责退场。
  void cancelPreparation() {
    if (committed) return;
    generation++;
    if (!_cancellation.isCompleted) _cancellation.complete();
    preparation.cancel();
    current?.cancel();
    current = null;
    active = false;
    preparing.value = false;
  }

  /// 展示提交后关闭准备层，展示锁仍保留。
  void commit() {
    committed = true;
    preparing.value = false;
  }

  /// 只有路由动画结束后才释放展示锁并允许下一点位进入。
  void finish() {
    preparation.cancel();
    current = null;
    committed = false;
    active = false;
    preparing.value = false;
  }

  /// 页面离开时终止尚未展示的准备任务。
  @override
  void onClose() {
    if (!committed) cancelPreparation();
    super.onClose();
  }
}
