import 'dart:async';
import 'dart:io';
import '../models/paywall_failure.dart';
import '../models/paywall_http_failure.dart';
import '../../web_paywall/services/web_paywall_diagnostics.dart';

/// 单次后台任务内最多三次尝试，等待联网和退避均响应宿主释放。
class PaywallQueryRetry {
  /// 只重试临时网络故障；权限、重定向、数据和摘要错误保持失败。
  static bool permits(Object error) {
    if (error is PaywallHttpFailure) {
      return error.statusCode == 408 ||
          error.statusCode == 429 ||
          (error.statusCode >= 500 && error.statusCode <= 599);
    }
    return error is SocketException || error is TimeoutException;
  }

  /// 各次尝试沿用原请求身份，不重新采集归因或环境。
  static Future<T> run<T>({
    required Future<T> Function() operation,
    required Future<void> Function() online,
    required Future<void> cancelled,
    required bool Function() isCancelled,
    required String environment,
    required String stage,
  }) async {
    for (var attempt = 0;; attempt++) {
      await online();
      if (isCancelled()) throw PaywallFailure.cancelled;
      try {
        return await operation();
      } catch (error) {
        if (isCancelled()) throw PaywallFailure.cancelled;
        if (attempt >= 2 || !permits(error)) rethrow;
        final delay = Duration(seconds: attempt == 0 ? 2 : 5);
        WebPaywallDiagnostics.log(environment, 'query.retry',
            'stage=$stage attempt=${attempt + 2} delay=${delay.inSeconds}');
        // 取消会清除退避计时器，不留下孤立任务。
        final wake = Completer<void>();
        final timer = Timer(delay, wake.complete);
        try {
          await Future.any([wake.future, cancelled]);
        } finally {
          timer.cancel();
        }
      }
    }
  }
}
