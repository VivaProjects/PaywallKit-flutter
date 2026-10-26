import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 补偿 Android 平台视图取整造成的右侧和底部缺口，保持原有裁剪与命中边界。
class WebPaywallOverscan extends StatelessWidget {
  const WebPaywallOverscan({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // 仅 Android 需要补偿物理像素取整；无界布局沿用原始视图。
          if (defaultTargetPlatform != TargetPlatform.android ||
              !constraints.hasBoundedWidth ||
              !constraints.hasBoundedHeight) {
            return child;
          }
          final extra = 1 / MediaQuery.devicePixelRatioOf(context);
          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: constraints.maxWidth + extra,
              maxWidth: constraints.maxWidth + extra,
              minHeight: constraints.maxHeight + extra,
              maxHeight: constraints.maxHeight + extra,
              child: child,
            ),
          );
        },
      );
}
