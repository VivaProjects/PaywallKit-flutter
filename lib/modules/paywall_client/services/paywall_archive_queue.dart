import 'dart:async';

/// 一个归档仓库拥有自己的有界队列，同包排队不占用其他包的工作槽。
class PaywallArchiveQueue {
  final _tails = <String, Future<void>>{};
  final _waiting = <Completer<void>>[];
  int _active = 0;

  /// 同一身份按调用顺序执行，每次仍使用自己的校验、取消条件和资源租约。
  Future<T> run<T>(String key, Future<T> Function() operation) {
    final previous = _tails[key] ?? Future<void>.value();
    final result = previous.then((_) => _withSlot(operation));
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tails[key] = tail;
    unawaited(tail.then((_) {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }));
    return result;
  }

  /// 两个不同包可同时准备；失败也归还槽位，不留下阻塞后续请求的队列尾。
  Future<T> _withSlot<T>(Future<T> Function() operation) async {
    if (_active >= 2) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await operation();
    } finally {
      // 直接把槽位交给最早等待者，新请求不能抢占已排队任务。
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }
}
