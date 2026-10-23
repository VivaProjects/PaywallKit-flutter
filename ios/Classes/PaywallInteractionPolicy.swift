import UIKit
import WebKit

/// 仅管理 SDK 指定的 WebView，不替换 webview_flutter 的导航或 UI delegate。
final class PaywallInteractionPolicy: UIGestureRecognizer {
    private weak var webView: WKWebView?

    /// 加载前注入所有框架，并在触摸开始前关闭动态安装的长按入口。
    init(webView: WKWebView, script: String) {
        self.webView = webView
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        if #available(iOS 14.5, *) { webView.configuration.preferences.isTextInteractionEnabled = false }
        webView.allowsLinkPreview = false
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        suppress(in: webView)
    }

    /// 观察触摸后立即失败，不争夺购买按钮或滚动手势。
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let webView { suppress(in: webView) }
        state = .failed
    }

    /// 关闭文字、图片、链接的原生长按与拖拽，保留其他识别器。
    private func suppress(in view: UIView) {
        for gesture in view.gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer {
            gesture.isEnabled = false
        }
        for interaction in view.interactions {
            if let drag = interaction as? UIDragInteraction { drag.isEnabled = false }
            if interaction is UIContextMenuInteraction { view.removeInteraction(interaction) }
        }
        for child in view.subviews { suppress(in: child) }
    }
}
