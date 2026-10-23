import 'package:flutter/foundation.dart';
import 'paywall_logging.dart';

/// 按独立日志模式输出，不依赖 Debug；业务环境始终使用实际配置。
class WebPaywallDiagnostics {
  /// 事件保持单行，调用方只传流程标识、状态与计数。
  static void log(String environment, String event, [String detail = '']) {
    if (!PaywallLogging.isEnabled(environment)) return;
    final line = '[PaywallKit][$environment] $event $detail'
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ');
    debugPrint(line);
  }
}
