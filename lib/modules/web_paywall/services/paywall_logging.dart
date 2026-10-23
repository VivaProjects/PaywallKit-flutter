/// 日志模式与交易环境独立；设置只作用于当前 Dart isolate。
enum PaywallLoggingMode { automatic, enabled, disabled }

/// 宿主可在创建 Client 前配置诊断输出，不改变请求、商品或缓存环境。
class PaywallLogging {
  static PaywallLoggingMode mode = PaywallLoggingMode.automatic;

  /// automatic 仅输出 test，显式开关适用于所有环境。
  static bool isEnabled(String environment) => switch (mode) {
        PaywallLoggingMode.automatic => environment == 'test',
        PaywallLoggingMode.enabled => true,
        PaywallLoggingMode.disabled => false,
      };
}
