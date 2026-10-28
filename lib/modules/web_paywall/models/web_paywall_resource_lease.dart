import 'dart:io';

/// 会话使用期间锁定资源目录，结束时显式归还。
class WebPaywallResourceLease {
  WebPaywallResourceLease(this.directory, this._release) {
    final key = directory.absolute.path;
    _active[key] = (_active[key] ?? 0) + 1;
  }
  static final _active = <String, int>{};
  static bool isInUse(Directory directory) =>
      (_active[directory.absolute.path] ?? 0) > 0;
  final Directory directory;
  final void Function() _release;
  bool _released = false;
  bool get isReleased => _released;
  String get pagePath => '${directory.path}/offline.html';

  /// 重复关闭无副作用，清理工作由资源仓库负责。
  void release() {
    if (_released) return;
    _released = true;
    final key = directory.absolute.path;
    final count = (_active[key] ?? 1) - 1;
    if (count <= 0)
      _active.remove(key);
    else
      _active[key] = count;
    _release();
  }
}
