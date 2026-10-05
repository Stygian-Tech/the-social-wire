import SwiftUI
import WebKit

struct TradingViewFinanceWidget: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    @State private var requested = false

    var body: some View {
        Group {
            if requested {
                FinanceWidgetWebView(symbol: symbol, dark: colorScheme == .dark)
                    .id("\(symbol):\(colorScheme)")
                    .frame(height: 230)
                    .accessibilityLabel("TradingView Performance Data")
            } else {
                Button("Show Market Overview", systemImage: "chart.line.uptrend.xyaxis") { requested = true }
            }
        }
    }
}

private struct FinanceWidgetWebView {
    let symbol: String
    let dark: Bool

    func configure(_ view: WKWebView) {
        guard symbol.range(of: "^[A-Za-z0-9_]+:[A-Za-z0-9_.!/-]+$", options: .regularExpression) != nil else { return }
        let config: [String: Any] = ["symbols": [[symbol]], "chartOnly": false, "width": "100%", "height": "220", "locale": "en", "colorTheme": dark ? "dark" : "light", "autosize": false, "showVolume": false]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return }
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"></head><body style="margin:0"><div class="tradingview-widget-container"><div class="tradingview-widget-container__widget"></div><div class="tradingview-widget-copyright"><a href="https://www.tradingview.com/" target="_blank" rel="noopener"><span>Track all markets on TradingView</span></a></div><script type="text/javascript" src="https://s3.tradingview.com/external-embedding/embed-widget-symbol-overview.js" async>\(json)</script></div></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }
}

#if os(macOS)
extension FinanceWidgetWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { let view = makeWebView(); configure(view); return view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension FinanceWidgetWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { let view = makeWebView(); configure(view); return view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
