import 'dart:io';

/// 会话使用期间锁定资源目录，结束时显式归还。
class WebPaywallResourceLease {
  WebPaywallResourceLease(this.directory, this._release);
  final Directory directory;
  final void Function() _release;
  bool _released = false;
  String get pagePath => '${directory.path}/offline.html';

  /// 重复关闭无副作用，清理工作由资源仓库负责。
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}
