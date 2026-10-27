#if os(iOS)
import Foundation

struct TradingViewChartConfiguration: Equatable, Sendable {
    let symbol: String
    let style: StockChartStyle
    let isDark: Bool

    var chartURL: URL {
        var components = URLComponents(string: "https://www.tradingview.com/chart/")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        return components.url!
    }

    func widgetJSON() throws -> String {
        // Defense in depth: never interpolate arbitrary post content into HTML or JavaScript.
        guard symbol.range(of: #"^(?:NASDAQ|NYSE|AMEX):[A-Z][A-Z0-9]{0,14}(?:\.[A-Z0-9]{1,4})?\z"#,
                           options: .regularExpression) != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let object: [String: Any] = [
            "symbol": symbol,
            "interval": "5",
            "range": "1D",
            "timezone": "exchange",
            "theme": isDark ? "dark" : "light",
            "style": style.tradingViewValue,
            "locale": "en",
            "autosize": true,
            "backgroundColor": isDark ? "rgba(0, 0, 0, 1)" : "rgba(255, 255, 255, 1)",
            "allow_symbol_change": false,
            "hide_top_toolbar": true,
            "hide_side_toolbar": true,
            "hide_legend": false,
            "withdateranges": false,
            "save_image": false,
            "calendar": false,
            "details": false,
            "support_host": "https://www.tradingview.com",
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    func html(loadID: Int = 0) throws -> String {
        let json = try widgetJSON()
        return """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        html,body{margin:0;height:100%;background:transparent;color-scheme:\(isDark ? "dark" : "light");}
        .tradingview-widget-container{height:100%;width:100%;}
        .tradingview-widget-container__widget{height:calc(100% - 32px);width:100%;}
        .tradingview-widget-copyright{height:32px;display:flex;align-items:center;justify-content:center;font:13px -apple-system,sans-serif;}
        .tradingview-widget-copyright a{color:#2962ff;text-decoration:none;}
        </style></head><body>
        <div class="tradingview-widget-container">
          <div class="tradingview-widget-container__widget"></div>
          <div class="tradingview-widget-copyright"><a href="https://www.tradingview.com/" rel="noopener nofollow" target="_blank"><span class="blue-text">Track all markets on TradingView</span></a></div>
          <script>
          // Observe our embedding element's lifecycle only; never read market data or iframe content.
          const report = state => window.webkit?.messageHandlers.chartLifecycle.postMessage({state, loadID: \(loadID)});
          const observer = new MutationObserver(() => {
            const frame = document.querySelector('.tradingview-widget-container iframe');
            if (frame) { frame.addEventListener('load', () => report('loaded'), {once:true}); observer.disconnect(); }
          });
          observer.observe(document.querySelector('.tradingview-widget-container'), {childList:true,subtree:true});
          </script>
          <script src="https://s3.tradingview.com/external-embedding/embed-widget-advanced-chart.js" async onerror="report('failed')">\(json)</script>
        </div></body></html>
        """
    }
}

#endif
