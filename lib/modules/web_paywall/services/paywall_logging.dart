import 'dart:io';
import 'paywall_log_store.dart';

/// 兼容旧调用；automatic 与 disabled 均不打印，所有模式均自动记录。
enum PaywallLoggingMode { automatic, enabled, disabled }

/// SDK 自行保存日志；唯一开关只控制控制台打印，不影响记录和诊断回调。
class PaywallLogging {
  static final _store = PaywallLogStore();
  static bool printsToConsole = false;

  /// 保留源代码兼容；推荐直接设置 printsToConsole。
  static PaywallLoggingMode get mode => printsToConsole
      ? PaywallLoggingMode.enabled
      : PaywallLoggingMode.disabled;
  static set mode(PaywallLoggingMode value) {
    printsToConsole = value == PaywallLoggingMode.enabled;
  }

  /// 兼容旧的打印状态查询；环境不影响 SDK 是否记录日志。
  static bool isEnabled(String environment) => printsToConsole;

  /// 只供 SDK 诊断入口写入，日志持久化失败不影响业务操作。
  static void record(String line) => _store.append(line);

  /// 等待已有写入，按时间顺序读取日志，关闭打印也可调用。
  static Future<String> read() => _store.read();

  /// 返回可分享的本地快照；不主动上传或发送到外部服务。
  static Future<File> export() => _store.export();

  /// 清理 SDK 日志，之后产生的日志仍正常记录。
  static Future<void> clear() => _store.clear();
}
