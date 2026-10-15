import '../controllers/web_paywall_controller.dart';

/// 宿主按入口持有一个句柄；路由接管后由 GetX 管理页面会话。
class WebPaywallPreloader {
  WebPaywallPreloader(this.createController);

  final WebPaywallController Function() createController;
  WebPaywallController? _pending;

  /// 在宿主选定的时机提前加载当前入口的 H5 与商店商品。
  void preload() {
    // 每次重新读取宿主参数，防止复用已注入旧环境或 custom 的页面。
    final controller = createController();
    if (_pending?.canReuseFor(controller) == true) {
      _pending?.trace('preload.reuse');
      return;
    }
    controller.trace('preload.start');
    destroy();
    // 未进入 GetX 路由，先启动加载；挂载时才启动首屏超时。
    _pending = controller;
    controller.preload();
  }

  /// Binding 调用一次后移交所有权，关闭路由会销毁该会话。
  WebPaywallController? take() {
    final controller = _pending;
    _pending = null;
    // 展示时再比较一次，覆盖预加载后、路由打开前的参数变化。
    if (controller?.canReuseFor(createController()) == true) {
      controller?.trace("preload.claim");
      return controller;
    }
    controller?.trace("preload.miss", "reason=invalid_or_identity_changed");
    controller?.destroyPreload();
    return null;
  }

  /// 场景失效或商品资格变化时释放未展示的预加载会话。
  void destroy() {
    _pending?.trace("preload.destroy");
    _pending?.destroyPreload();
    _pending = null;
  }
}
