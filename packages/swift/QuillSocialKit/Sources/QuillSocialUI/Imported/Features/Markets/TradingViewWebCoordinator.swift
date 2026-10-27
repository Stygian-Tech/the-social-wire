#if os(iOS)
import SwiftUI
import WebKit

@MainActor
final class TradingViewWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var loadState: Binding<TradingViewLoadState>
    var openURL: OpenURLAction
    private var currentConfiguration: TradingViewChartConfiguration?
    private var timeout: Task<Void, Never>?
    private var isStopped = false
    private(set) var loadID = 0
    private var navigation: WKNavigation?

    init(loadState: Binding<TradingViewLoadState>, openURL: OpenURLAction) {
        self.loadState = loadState
        self.openURL = openURL
    }

    func load(_ configuration: TradingViewChartConfiguration, in view: WKWebView) {
        guard currentConfiguration != configuration else { return }
        currentConfiguration = configuration
        isStopped = false
        loadID += 1
        let generation = loadID
        timeout?.cancel()
        timeout = Task { [weak self] in
            // UIKit calls updateUIView during SwiftUI rendering; publish state after yielding.
            await Task.yield()
            guard let self, !Task.isCancelled, !self.isStopped, self.loadID == generation else { return }
            self.loadState.wrappedValue = .loading
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard !Task.isCancelled, !self.isStopped, self.loadID == generation, self.loadState.wrappedValue == .loading else { return }
            self.loadState.wrappedValue = .failed
            view.stopLoading()
            view.loadHTMLString("", baseURL: nil)
        }
        do {
            navigation = view.loadHTMLString(try configuration.html(loadID: generation), baseURL: URL(string: "https://quillapp.at/"))
        } catch {
            publish(.failed, loadID: generation)
        }
    }

    func stop() {
        isStopped = true
        loadID += 1
        timeout?.cancel()
        timeout = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isStopped, message.frameInfo.isMainFrame, message.name == "chartLifecycle",
              let body = message.body as? [String: Any],
              let state = body["state"] as? String,
              let generation = body["loadID"] as? Int else { return }
        receive(state, loadID: generation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        publish(.failed)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            if url.scheme == "https" || url.scheme == "http" { openURL(url) }
            return .cancel
        }
        // Allow the hosted widget's subframes, but never navigate the embedding document away.
        if navigationAction.targetFrame?.isMainFrame == true {
            return url.scheme == "about" || url.host == "quillapp.at" ? .allow : .cancel
        }
        return url.scheme == "https" || url.scheme == "about" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { openURL(url) }
        return nil
    }

    private func handle(_ error: any Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        publish(.failed)
    }

    func receive(_ state: String, loadID generation: Int) {
        guard !isStopped, generation == loadID else { return }
        switch state {
        case "loaded": publish(.loaded, loadID: generation)
        case "failed": publish(.failed, loadID: generation)
        default: break
        }
    }

    private func publish(_ state: TradingViewLoadState, loadID generation: Int? = nil) {
        let generation = generation ?? loadID
        guard !isStopped, generation == loadID else { return }
        timeout?.cancel()
        Task { [weak self] in
            guard let self, !self.isStopped, self.loadID == generation else { return }
            self.loadState.wrappedValue = state
        }
    }
}

#endif
