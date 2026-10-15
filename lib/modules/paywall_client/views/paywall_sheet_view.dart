import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/paywall_flow_controller.dart';
import '../controllers/paywall_sheet_controller.dart';
import '../../web_paywall/models/web_paywall_configuration.dart';

/// 半屏只移动已渲染表面，锁定模式禁止遮罩、拖动与返回关闭。
class PaywallSheetView extends StatefulWidget {
  const PaywallSheetView(
      {super.key, required this.controller, required this.child});
  final PaywallFlowController controller;
  final Widget child;
  @override
  State<PaywallSheetView> createState() => _PaywallSheetViewState();
}

class _PaywallSheetViewState extends State<PaywallSheetView> {
  late final PaywallSheetController layout;
  Worker? _webWorker, _heightWorker;
  bool get locked =>
      widget.controller.presentation ==
          WebPaywallPresentation.halfSheetLocked ||
      !widget.controller.allowsDismiss;

  /// 控制器持有高度状态，Widget 只订阅当前网页并转发布局变化。
  @override
  void initState() {
    super.initState();
    layout = PaywallSheetController();
    _bindHeight();
    _webWorker = ever(widget.controller.web, (_) => _bindHeight());
  }

  /// 回退更换 WebView 时丢弃旧高度监听，新的页面独立定高。
  void _bindHeight() {
    _heightWorker?.dispose();
    layout.height.value = null;
    final web = widget.controller.web.value;
    if (web == null) return;
    layout.seed(web.contentHeight.value);
    _heightWorker = ever(web.contentHeight, (value) {
      if (value != null) layout.report(value);
    });
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        // 屏幕宽度变化才解锁视口，拖动期间固定内容大小。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) layout.layoutWidth(constraints.maxWidth);
        });
        final available =
            (constraints.maxHeight - MediaQuery.paddingOf(context).top)
                .clamp(1.0, double.infinity);
        return Stack(children: [
          Positioned.fill(
              child: GestureDetector(
                  onTap: locked ? null : widget.controller.close,
                  child: const ColoredBox(color: Colors.black54))),
          Align(
              alignment: Alignment.bottomCenter,
              child: Obx(() => Transform.translate(
                  offset: Offset(0, layout.dragOffset.value),
                  child: SizedBox(
                      height: (layout.height.value == null
                              ? available
                              : layout.height.value! +
                                  (locked ? 0 : 24) +
                                  MediaQuery.paddingOf(context).bottom)
                          .clamp(1.0, available),
                      width: constraints.maxWidth,
                      child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(20)),
                          child: Column(children: [
                            if (!locked)
                              GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onVerticalDragUpdate: (event) => layout
                                          .dragOffset.value =
                                      (layout.dragOffset.value + event.delta.dy)
                                          .clamp(0, available),
                                  onVerticalDragEnd: (event) {
                                    if (layout.dragOffset.value > 80 ||
                                        (event.primaryVelocity ?? 0) > 700)
                                      widget.controller.close();
                                    else
                                      layout.dragOffset.value = 0;
                                  },
                                  child: Container(
                                      height: 24,
                                      color: Theme.of(context)
                                          .scaffoldBackgroundColor,
                                      alignment: Alignment.center,
                                      child: Container(
                                          width: 36,
                                          height: 4,
                                          decoration: BoxDecoration(
                                              color: Colors.grey,
                                              borderRadius:
                                                  BorderRadius.circular(2))))),
                            Expanded(
                                child:
                                    SafeArea(top: false, child: widget.child)),
                          ]))))))
        ]);
      });

  /// 退出时注销所有监听和延迟任务，避免旧页影响下次展示。
  @override
  void dispose() {
    _webWorker?.dispose();
    _heightWorker?.dispose();
    layout.dispose();
    super.dispose();
  }
}
