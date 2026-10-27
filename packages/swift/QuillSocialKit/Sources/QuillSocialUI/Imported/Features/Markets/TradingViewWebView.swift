#if os(iOS)
import SwiftUI
import WebKit

/// A narrow bridge for TradingView's hosted embed; it never handles user credentials.
struct TradingViewWebView: UIViewRepresentable {
    let configuration: TradingViewChartConfiguration
    @Binding var loadState: TradingViewLoadState
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> TradingViewWebCoordinator {
        TradingViewWebCoordinator(loadState: $loadState, openURL: openURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "chartLifecycle")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.underPageBackgroundColor = .clear
        view.allowsLinkPreview = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.openURL = openURL
        context.coordinator.load(configuration, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: TradingViewWebCoordinator) {
        coordinator.stop()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "chartLifecycle")
        // Destroy the document as well as any active hosted frame/WebSocket when offscreen.
        view.loadHTMLString("", baseURL: nil)
    }
}

#endif
