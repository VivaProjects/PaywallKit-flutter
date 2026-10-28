import 'package:flutter/foundation.dart';
import 'paywall_logging.dart';

/// 按独立日志模式输出，不依赖 Debug；业务环境始终使用实际配置。
class WebPaywallDiagnostics {
  static final _clock = Stopwatch()..start();
  static int _nextSpan = 0;
  static final _runID = DateTime.now().microsecondsSinceEpoch.toRadixString(16);

  /// 单调计时只记录阶段与安全标识，异常按原样传回，不输出错误正文。
  static Future<T> measure<T>(
      String environment, String stage, Future<T> Function() operation,
      {String detail = ''}) async {
    final id = ++_nextSpan;
    final started = Stopwatch()..start();
    log(environment, '$stage.begin', 'span=$id $detail');
    try {
      final value = await operation();
      log(environment, '$stage.end',
          'span=$id durationMs=${started.elapsedMilliseconds} status=ok $detail');
      return value;
    } catch (error) {
      log(environment, '$stage.end',
          'span=$id durationMs=${started.elapsedMilliseconds} status=error errorType=${error.runtimeType} $detail');
      rethrow;
    }
  }

  /// 事件保持单行，调用方只传流程标识、状态与计数。
  static void log(String environment, String event, [String detail = '']) {
    final line =
        '[PaywallKit][$environment] $event sdk=flutter run=$_runID wallMs=${DateTime.now().millisecondsSinceEpoch} tMs=${_clock.elapsedMilliseconds} $detail'
            .replaceAll('\n', ' ')
            .replaceAll('\r', ' ');
    PaywallLogging.record(line);
    if (PaywallLogging.printsToConsole) debugPrint(line);
  }
}
