import 'package:flutter/foundation.dart';

/// 只按显式测试环境输出，不依赖 Debug，也不记录桥载荷和用户数据。
class WebPaywallDiagnostics {
  /// 事件保持单行，调用方只传流程标识、状态与计数。
  static void log(String environment, String event, [String detail = '']) {
    if (environment != 'test') return;
    final line = '[PaywallKit][test] $event $detail'
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ');
    debugPrint(line);
  }
}
