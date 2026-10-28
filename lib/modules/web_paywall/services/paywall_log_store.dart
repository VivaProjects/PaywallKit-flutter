import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// SDK 独立拥有的滚动日志；磁盘串行写入，内存与文件均有容量上限。
class PaywallLogStore {
  PaywallLogStore(
      {Future<Directory> Function()? directory,
      this.fileBytes = 1024 * 1024,
      this.bufferBytes = 128 * 1024})
      : _directory = directory ?? _nativeDirectory;
  final Future<Directory> Function() _directory;
  final int fileBytes, bufferBytes;
  final _buffer = ListQueue<String>();
  int _bytes = 0, _dropped = 0;
  bool _scheduled = false;
  bool _storageFailed = false;
  Future<void> _tail = Future.value();

  /// 与资源使用同一平台私有根目录，但日志不参与资源缓存清理。
  static Future<Directory> _nativeDirectory() async {
    final path = await const MethodChannel('native_paywall/resources')
        .invokeMethod<String>('directory');
    if (path == null)
      throw const FileSystemException('Log directory unavailable');
    return Directory('$path/diagnostics');
  }

  /// 高频事件合并成一批后台写入；失败只保留有界内存，不影响支付墙。
  void append(String line) {
    _add(String.fromCharCodes(line.runes.take(2048)) +
        (line.runes.length > 2048 ? ' [truncated]' : '') +
        '\n');
    _schedule();
  }

  /// 当前批次写完后继续处理新到事件，磁盘失败则等待下一次事件或读取再尝试。
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    unawaited(_enqueue(() async {
      final success = await _flush();
      _scheduled = false;
      if (success && (_buffer.isNotEmpty || _dropped > 0)) _schedule();
    }));
  }

  /// 内存超限时保留最新事件，并记录丢弃数量，不能静默伪装成完整日志。
  void _add(String line) {
    _buffer.add(line);
    _bytes += utf8.encode(line).length;
    while (_bytes > bufferBytes && _buffer.isNotEmpty) {
      _bytes -= utf8.encode(_buffer.removeFirst()).length;
      _dropped++;
    }
  }

  /// 文件操作共用队列；读取、导出和清理可等待先前写入结束。
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final task = _tail.then((_) => operation());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  /// 每批使用写入前的缓冲快照；失败恢复未确认数据，后续事件或读取可重试。
  Future<bool> _flush() async {
    if (_buffer.isEmpty && _dropped == 0) return true;
    final lines = _buffer.toList();
    if (_dropped > 0)
      lines.insert(0, '[PaywallKit] logs.dropped count=$_dropped\n');
    _buffer.clear();
    _bytes = 0;
    _dropped = 0;
    try {
      final root = await _directory();
      await root.create(recursive: true);
      await _write(root, lines);
      _storageFailed = false;
      return true;
    } catch (_) {
      _storageFailed = true;
      final newer = _buffer.toList();
      _buffer.clear();
      _bytes = 0;
      for (final line in [...lines, ...newer]) {
        _add(line);
      }
      return false;
    }
  }

  /// 每批按文件容量分段追加，最多保留当前文件和两个旧文件。
  Future<void> _write(Directory root, List<String> lines) async {
    final current = File('${root.path}/paywall-0.log');
    var size = await current.exists() ? await current.length() : 0;
    var chunk = StringBuffer();
    for (final original in lines) {
      final line = utf8.encode(original).length <= fileBytes
          ? original
          : '[PaywallKit] logs.line_too_large\n';
      final length = utf8.encode(line).length;
      if (size + length > fileBytes) {
        if (chunk.isNotEmpty)
          await current.writeAsString(chunk.toString(), mode: FileMode.append);
        await _rotate(root);
        chunk = StringBuffer();
        size = 0;
      }
      chunk.write(line);
      size += length;
    }
    if (chunk.isNotEmpty)
      await current.writeAsString(chunk.toString(), mode: FileMode.append);
  }

  /// 仅轮转 SDK 自己的固定文件名，不触碰宿主文件和资源包。
  Future<void> _rotate(Directory root) async {
    final oldest = File('${root.path}/paywall-2.log');
    if (await oldest.exists()) await oldest.delete();
    for (var index = 1; index >= 0; index--) {
      final file = File('${root.path}/paywall-$index.log');
      if (await file.exists())
        await file.rename('${root.path}/paywall-${index + 1}.log');
    }
  }

  /// 从旧到新返回已有日志；平台目录不可用时仍可分析内存缓冲。
  Future<String> read() => _enqueue(() async {
        await _flush();
        return _read();
      });

  /// 读取最多三个滚动文件，损坏或不可读的单文件不影响其余日志。
  Future<String> _read() async {
    final result = StringBuffer();
    if (_storageFailed)
      result.writeln('[PaywallKit] logs.storage_unavailable source=memory');
    try {
      final root = await _directory();
      for (var index = 2; index >= 0; index--) {
        final file = File('${root.path}/paywall-$index.log');
        if (!await file.exists()) continue;
        try {
          result.write(
              utf8.decode(await file.readAsBytes(), allowMalformed: true));
        } catch (_) {
          result.writeln('[PaywallKit] logs.read_failed file=$index');
        }
      }
    } catch (_) {
      result.writeln('[PaywallKit] logs.storage_unavailable source=memory');
    }
    if (_dropped > 0)
      result.writeln('[PaywallKit] logs.dropped count=$_dropped');
    result.writeAll(_buffer);
    return result.toString();
  }

  /// 导出到固定快照文件并返回路径；再次导出覆盖，避免导出副本无限增长。
  Future<File> export() => _enqueue(() async {
        await _flush();
        final root = await _directory();
        await root.create(recursive: true);
        final file = File('${root.path}/paywall-export.log');
        await file.writeAsString(await _read(), flush: true);
        return file;
      });

  /// 清除已有日志和导出副本；之后产生的新日志仍自动记录。
  Future<void> clear() => _enqueue(() async {
        _buffer.clear();
        _bytes = 0;
        _dropped = 0;
        final root = await _directory();
        for (final name in [
          'paywall-0.log',
          'paywall-1.log',
          'paywall-2.log',
          'paywall-export.log'
        ]) {
          final file = File('${root.path}/$name');
          if (await file.exists()) await file.delete();
        }
      });
}
