import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 会话持有唯一平台视图；路由只提供位置锚点，隐藏和再次展示不卸载 WebView。
class WebPaywallResidentSurface {
  WebPaywallResidentSurface(WebViewController controller)
      : _view = WebViewWidget(
          controller: controller,
          // 常驻表面同样保留网页滚动，不让祖先拖动手势截获内容滑动。
          gestureRecognizers: {
            Factory<VerticalDragGestureRecognizer>(
                VerticalDragGestureRecognizer.new),
          },
        );

  final Widget _view;
  final link = LayerLink();
  OverlayEntry? _entry;
  OverlayState? _overlay;
  Object? _owner;
  Size _size = Size.zero;
  bool _visible = false;
  bool _disposed = false;

  /// 帧结束后接管锚点，保持平台视图元素不变并移动到当前路由上方。
  void attach(Object owner, OverlayState overlay, Size size, bool visible) {
    if (_disposed || !overlay.mounted) return;
    final changedOwner = !identical(_owner, owner);
    _owner = owner;
    _size = size;
    _visible = visible;
    if (_entry == null) {
      _overlay = overlay;
      _entry = OverlayEntry(maintainState: true, builder: _build);
      overlay.insert(_entry!);
    } else if (!identical(_overlay, overlay)) {
      // Navigator 所属改变不能跨 Overlay 搬移原生表面；保持隐藏等待原宿主。
      _visible = false;
    } else if (changedOwner) {
      // 未列出的路由条目放到常驻表面下方，不能使用默认的置底行为。
      overlay.rearrange([_entry!], below: _entry);
    }
    _entry?.markNeedsBuild();
  }

  /// 旧路由卸载只隐藏表面；所有权检查避免覆盖新路由已接管的状态。
  void detach(Object owner) {
    if (_disposed || !identical(_owner, owner)) return;
    _owner = null;
    _visible = false;
    _refreshAfterFrame();
  }

  /// 生命周期回调可能发生在布局阶段，延后刷新避免构建中修改 Overlay。
  void _refreshAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _entry?.markNeedsBuild();
    });
  }

  /// 根 Overlay 中的固定元素保留原生实例，跟随路由动画和实际内容尺寸。
  Widget _build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          ignoring: !_visible,
          child: ExcludeSemantics(
            excluding: !_visible,
            child: Opacity(
              opacity: _visible ? 1 : 0,
              child: CompositedTransformFollower(
                link: link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.topLeft,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox.fromSize(
                    size: _size,
                    child: ClipRect(child: _view),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// 环境、权益、页面版本失效或 Client 释放时，真正移除常驻平台视图。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final entry = _entry;
    _entry = null;
    _owner = null;
    _visible = false;
    if (entry == null) return;
    // remove 支持构建期间调用；元素在当前帧结束后由 Overlay 释放。
    entry.remove();
    entry.dispose();
  }
}
