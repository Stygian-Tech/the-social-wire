import SwiftUI
import WebKit

/// Opens in-article link taps in the system browser instead of navigating inside the embed.
final class ArticleWebNavigationHandling: NSObject, WKNavigationDelegate {
    static let shared = ArticleWebNavigationHandling()

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url
        {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// WKWebView that does not publish intrinsic height — avoids layout feedback loops when embedded in stacks.
private final class StableHeightWebView: WKWebView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

private func configureArticleWebView(_ webView: WKWebView, coordinator: NSObject & WKNavigationDelegate) {
    webView.isOpaque = false
    webView.backgroundColor = .clear
    if #available(iOS 15.0, *) {
        webView.underPageBackgroundColor = .clear
    }
    webView.navigationDelegate = coordinator
    webView.scrollView.isScrollEnabled = true
    webView.scrollView.bounces = true
    webView.scrollView.contentInsetAdjustmentBehavior = .automatic
    webView.scrollView.delaysContentTouches = false
}

struct HTMLWebView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let html: String
    var baseURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = StableHeightWebView(frame: .zero, configuration: configuration)
        configureArticleWebView(webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let wrapped = HTMLRenderer.wrappedHTML(html, colorScheme: colorScheme)
        let loadKey = HTMLWebView.LoadKey(html: html, colorScheme: colorScheme, baseURL: baseURL)
        guard context.coordinator.loadedKey != loadKey else { return }
        context.coordinator.loadedKey = loadKey
        webView.loadHTMLString(wrapped, baseURL: baseURL)
    }

    fileprivate struct LoadKey: Equatable {
        let html: String
        let colorScheme: ColorScheme
        let baseURL: URL?
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        fileprivate var loadedKey: LoadKey?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            ArticleWebNavigationHandling.shared.webView(
                webView,
                decidePolicyFor: navigationAction,
                decisionHandler: decisionHandler
            )
        }
    }
}

struct WebPreview: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = StableHeightWebView()
        webView.allowsBackForwardNavigationGestures = false
        configureArticleWebView(webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            ArticleWebNavigationHandling.shared.webView(
                webView,
                decidePolicyFor: navigationAction,
                decisionHandler: decisionHandler
            )
        }
    }
}
