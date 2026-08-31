import SwiftUI
import WebKit

/// Opens in-article link taps in the system browser instead of navigating inside the embed.
@MainActor
final class ArticleWebNavigationHandling: NSObject, WKNavigationDelegate {
    static let shared = ArticleWebNavigationHandling()

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url
        {
            PlatformURLOpener.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

#if canImport(UIKit)
import UIKit

/// WKWebView that does not publish intrinsic height — avoids layout feedback loops when embedded in stacks.
private final class StableHeightWebView: WKWebView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

@MainActor
private func configureArticleWebView(_ webView: WKWebView, coordinator: NSObject & WKNavigationDelegate) {
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.underPageBackgroundColor = .clear
    webView.navigationDelegate = coordinator
    webView.scrollView.isScrollEnabled = true
    webView.scrollView.bounces = true
    webView.scrollView.alwaysBounceVertical = false
    webView.scrollView.contentInsetAdjustmentBehavior = .automatic
    webView.scrollView.delaysContentTouches = false
}

struct HTMLWebView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let html: String
    var baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = StableHeightWebView(frame: .zero, configuration: configuration)
        configureArticleWebView(webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let loadKey = LoadKey(html: html, colorScheme: colorScheme, baseURL: baseURL)
        guard context.coordinator.loadedKey != loadKey else { return }
        context.coordinator.loadedKey = loadKey
        webView.loadHTMLString(HTMLRenderer.wrappedHTML(html, colorScheme: colorScheme), baseURL: baseURL)
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
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
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

    func makeCoordinator() -> Coordinator { Coordinator() }

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
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            ArticleWebNavigationHandling.shared.webView(
                webView,
                decidePolicyFor: navigationAction,
                decisionHandler: decisionHandler
            )
        }
    }
}
#elseif canImport(AppKit)
import AppKit

/// WKWebView that does not publish intrinsic height — avoids layout feedback loops when embedded in stacks.
private final class StableHeightWebView: WKWebView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

@MainActor
private func configureArticleWebView(_ webView: WKWebView, coordinator: NSObject & WKNavigationDelegate) {
    webView.underPageBackgroundColor = .clear
    webView.navigationDelegate = coordinator
}

struct HTMLWebView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let html: String
    var baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = StableHeightWebView(frame: .zero, configuration: configuration)
        configureArticleWebView(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let loadKey = LoadKey(html: html, colorScheme: colorScheme, baseURL: baseURL)
        guard context.coordinator.loadedKey != loadKey else { return }
        context.coordinator.loadedKey = loadKey
        webView.loadHTMLString(HTMLRenderer.wrappedHTML(html, colorScheme: colorScheme), baseURL: baseURL)
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
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            ArticleWebNavigationHandling.shared.webView(
                webView,
                decidePolicyFor: navigationAction,
                decisionHandler: decisionHandler
            )
        }
    }
}

struct WebPreview: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = StableHeightWebView()
        webView.allowsBackForwardNavigationGestures = false
        configureArticleWebView(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            ArticleWebNavigationHandling.shared.webView(
                webView,
                decidePolicyFor: navigationAction,
                decisionHandler: decisionHandler
            )
        }
    }
}
#endif
