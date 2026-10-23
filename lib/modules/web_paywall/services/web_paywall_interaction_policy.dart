import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// 仅对本会话 WebView 关闭选择与长按菜单，保留点击和滚动。
class WebPaywallInteractionPolicy {
  static const script = r"""
(() => {
  if (window.__paywallInteractionPolicy) return;
  window.__paywallInteractionPolicy = true;
  const install = () => {
    const style = document.createElement('style');
    style.textContent = '*{-webkit-user-select:none!important;user-select:none!important;-webkit-touch-callout:none!important;-webkit-user-drag:none!important}';
    document.documentElement.appendChild(style);
  };
  if (document.documentElement) install();
  else document.addEventListener('DOMContentLoaded', install, {once:true});
  for (const name of ['selectstart','copy','cut','contextmenu','dragstart']) {
    document.addEventListener(name, event => {
      event.preventDefault(); event.stopImmediatePropagation();
    }, true);
  }
})();
""";

  /// 通过插件公开实例 ID 定位当前 WebView，不遍历或修改宿主其他页面。
  static Future<void> install(WebViewController controller) async {
    final platform = controller.platform;
    final int identifier;
    if (platform is AndroidWebViewController) {
      identifier = platform.webViewIdentifier;
    } else if (platform is WebKitWebViewController) {
      identifier = platform.webViewIdentifier;
    } else {
      return;
    }
    await const MethodChannel('native_paywall/resources').invokeMethod<void>(
        'disableLongPress', {'identifier': identifier, 'script': script});
  }
}
