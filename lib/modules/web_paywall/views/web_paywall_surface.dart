import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../controllers/web_paywall_controller.dart';
import '../services/web_paywall_resident_surface.dart';
import 'web_paywall_overscan.dart';

/// Android 常驻入口使用位置锚点，其他页面继续沿用原有 WebView 布局。
class WebPaywallSurface extends StatefulWidget {
  const WebPaywallSurface({
    super.key,
    required this.controller,
    required this.visible,
  });

  final WebPaywallController controller;
  final bool visible;

  @override
  State<WebPaywallSurface> createState() => _WebPaywallSurfaceState();
}

class _WebPaywallSurfaceState extends State<WebPaywallSurface> {
  static final _surfaces = Expando<WebPaywallResidentSurface>();
  WebPaywallResidentSurface? _surface;
  final _owner = Object();
  int _generation = 0;

  /// 表面与会话同寿命，隐藏准备视图和展示路由取得同一个原生实例。
  WebPaywallResidentSurface _resident() {
    if (_surface != null) return _surface!;
    final controller = widget.controller;
    final existing = _surfaces[controller];
    if (existing != null) {
      controller.trace('surface.reuse');
      return _surface = existing;
    }
    final created = WebPaywallResidentSurface(controller.webView);
    _surfaces[controller] = created;
    controller.trace('surface.create');
    controller.releaseSurface = () {
      controller.trace('surface.release');
      created.dispose();
    };
    return _surface = created;
  }

  /// 回退或报价变化更换会话时解绑旧锚点，由控制器负责释放旧表面。
  @override
  void didUpdateWidget(covariant WebPaywallSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _generation++;
      _surface?.detach(_owner);
      _surface = null;
    }
  }

  /// 路由退出只解除位置关联；保留中的会话继续持有 Overlay 平台视图。
  @override
  void dispose() {
    _generation++;
    _surface?.detach(_owner);
    super.dispose();
  }

  /// 仅当前路由允许显示和触摸，法律页或其他覆盖路由出现时隐藏常驻表面。
  @override
  Widget build(BuildContext context) {
    if (!widget.controller.keepSurfaceAlive ||
        defaultTargetPlatform != TargetPlatform.android) {
      // 内容纵向拖动交给网页，避免 Settings 外层 BottomSheet 抢走滚动。
      return WebPaywallOverscan(
        child: WebViewWidget(
          controller: widget.controller.webView,
          gestureRecognizers: {
            Factory<VerticalDragGestureRecognizer>(
                VerticalDragGestureRecognizer.new),
          },
        ),
      );
    }
    final surface = _resident();
    final overlay = Overlay.of(context, rootOverlay: true);
    final route = ModalRoute.of(context);
    // 退场动画仍跟随当前表面；被法律页等新路由覆盖时则立即隐藏。
    final routeVisible = route == null ||
        route.isCurrent ||
        route.animation?.status == AnimationStatus.reverse;
    final visible = widget.visible && routeVisible;
    return LayoutBuilder(builder: (context, constraints) {
      final generation = ++_generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation) return;
        surface.attach(_owner, overlay, constraints.biggest, visible);
      });
      return CompositedTransformTarget(
        link: surface.link,
        child: const SizedBox.expand(),
      );
    });
  }
}
