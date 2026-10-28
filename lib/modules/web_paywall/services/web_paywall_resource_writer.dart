import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// 每个下载包复用一个后台工作者，避免每个小文件重复创建 isolate。
class WebPaywallResourceWriter {
  WebPaywallResourceWriter._();
  final _receive = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<void>>{};
  Isolate? _isolate;
  var _next = 0;
  var _closed = false;

  /// 工作者只处理字节、文件元数据与目标路径，不访问平台或宿主对象。
  static Future<WebPaywallResourceWriter> start() async {
    final writer = WebPaywallResourceWriter._();
    writer._receive.listen(writer._message);
    try {
      writer._isolate = await Isolate.spawn(_run, writer._receive.sendPort,
          onError: writer._receive.sendPort, onExit: writer._receive.sendPort);
      await writer._ready.future;
      return writer;
    } catch (_) {
      writer.close();
      rethrow;
    }
  }

  /// 后台异常结束必须结束所有等待者，不能留下悬空的下载槽位。
  void _message(dynamic message) {
    if (message is SendPort) {
      _ready.complete(message);
    } else if (message is List && message.first is int) {
      final waiter = _pending.remove(message[0]);
      if (message[1] == null) {
        waiter?.complete();
      } else {
        waiter?.completeError(message[1] as Object);
      }
    } else {
      final error = StateError('Resource writer stopped: $message');
      if (!_ready.isCompleted) _ready.completeError(error);
      close();
    }
  }

  /// 可转移字节避免消息再复制大文件；完成回执表示摘要校验与写盘均成功。
  Future<void> write(
      List<int> data, Map<String, dynamic> asset, String path) async {
    if (_closed) throw StateError('Resource writer closed');
    final port = await _ready.future;
    if (_closed) throw StateError('Resource writer closed');
    final id = _next++;
    final waiter = Completer<void>();
    _pending[id] = waiter;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    port.send([
      id,
      TransferableTypedData.fromList([bytes]),
      asset,
      path
    ]);
    await waiter.future;
  }

  /// 所有在途写入退出后由包下载 finally 释放，失败和正常路径共用清理。
  void close() {
    if (_closed) return;
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _receive.close();
    for (final waiter in _pending.values) {
      waiter.completeError(StateError('Resource writer closed'));
    }
    _pending.clear();
  }

  /// 每条消息独立校验，错误回传原异常；主 isolate 决定整包失败和清理。
  static void _run(SendPort output) {
    final receive = ReceivePort();
    output.send(receive.sendPort);
    receive.listen((dynamic message) {
      final values = message as List;
      try {
        final data =
            (values[1] as TransferableTypedData).materialize().asUint8List();
        final asset = values[2] as Map;
        if (data.length != asset['size'] ||
            sha256.convert(data).toString() != asset['sha256']) {
          throw FormatException('Resource hash mismatch: ${asset['path']}');
        }
        final file = File(values[3] as String);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data, flush: true);
        output.send([values[0], null]);
      } catch (error) {
        output.send([values[0], error]);
      }
    });
  }
}
