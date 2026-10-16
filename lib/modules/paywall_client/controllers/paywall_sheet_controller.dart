import 'dart:async';
import 'package:flutter/foundation.dart';

/// 半屏只接受本次宽度下首个稳定高度，手势拖动不改变 H5 视口。
class PaywallSheetController {
  final height = ValueNotifier<double?>(null);
  final dragOffset = ValueNotifier(0.0);
  double? _width, _reported;
  Timer? _timer;

  /// 真实宽度变化解除高度锁，竖向手势只移动已渲染表面。
  void layoutWidth(double width) {
    if (_width == width) return;
    if (_width == null) {
      _width = width;
      return;
    }
    _width = width;
    height.value = null;
    if (_reported != null) report(_reported!);
  }

  /// 200ms 内连续上报合并，确定后不因 Sheet 尺寸变化反复重排。
  void report(double value) {
    if (!value.isFinite || value <= 0 || value > 100000) return;
    _reported = value;
    if (height.value != null) return;
    _timer?.cancel();
    _timer =
        Timer(const Duration(milliseconds: 200), () => height.value = value);
  }

  /// 预渲染已经得到内容高度时直接带入，避免先大后小的闪动。
  void seed(double? value) {
    if (value == null || !value.isFinite || value <= 0 || value > 100000)
      return;
    _reported = value;
    height.value = value;
  }

  /// 释放延迟定高任务，退出后不得继续修改页面状态。
  void dispose() {
    _timer?.cancel();
    height.dispose();
    dragOffset.dispose();
  }
}
