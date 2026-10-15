import 'dart:async';
import 'dart:io';
import 'paywall_storage.dart';
import '../models/paywall_failure.dart';

/// 通用归因状态独立于第三方 SDK；失败和超时默认值仅保留在内存。
class PaywallQueryAttribution {
  PaywallQueryAttribution(
      {required this.storage,
      required this.namespace,
      this.wait = const Duration(seconds: 5)});
  final PaywallStorage storage;
  final String namespace;
  final Duration wait;
  String? channel;
  void Function()? onChange;
  Future<void>? _initializing;
  final _changed = Completer<void>();
  bool _disposed = false;
  int _generation = 0;
  Future<void> _writes = Future.value();

  /// 冷启动优先复用已确认归因，外部回调先到时不被旧磁盘值覆盖。
  Future<void> initialize() => _initializing ??= _restore();

  /// 只读取本宿主与本环境的已确认渠道。
  Future<void> _restore() async {
    final generation = _generation;
    try {
      final saved = await PaywallStorage.read(await _file());
      final value = saved['channel'];
      if (generation == _generation &&
          value is String &&
          value.trim().isNotEmpty &&
          !_disposed) channel = value;
    } catch (_) {/* 首次安装与损坏状态继续等待真实回调。 */}
  }

  /// 成功自然量可持久化；失败不能覆盖已确认渠道。
  Future<void> update({String? channel, bool failed = false}) async {
    if (_disposed) return;
    await initialize();
    final previous = this.channel;
    final resolved =
        channel == null || channel.trim().isEmpty ? 'organic' : channel;
    this.channel = failed ? this.channel ?? 'organic' : resolved;
    if (!_changed.isCompleted) _changed.complete();
    if (previous != this.channel) onChange?.call();
    if (failed) return;
    final generation = ++_generation;
    // 串行落盘，晚到的旧写不能覆盖最近一次成功归因。
    final task = _writes.then((_) async {
      if (_disposed || generation != _generation) return;
      await PaywallStorage.write(await _file(), {'channel': resolved},
          isCurrent: () => !_disposed && generation == _generation);
    });
    _writes = task.catchError((Object _) {});
    await _writes;
  }

  /// 未知归因最多等待五秒，不把超时 organic 持久化。
  Future<String> resolve() async {
    await initialize();
    if (_disposed) throw PaywallFailure.cancelled;
    if (channel == null) {
      await _changed.future.timeout(wait, onTimeout: () {});
    }
    if (_disposed) throw PaywallFailure.cancelled;
    return channel ?? 'organic';
  }

  /// 环境由 namespace 隔离，避免 Test 与 Production 共用归因结果。
  Future<File> _file() async => File(
      '${(await storage.folder('attribution', namespace)).path}/state.json');

  /// 释放时唤醒等待者，避免关闭流程继续触发新配置请求。
  void dispose() {
    _disposed = true;
    _generation++;
    if (!_changed.isCompleted) _changed.complete();
    onChange = null;
  }
}
