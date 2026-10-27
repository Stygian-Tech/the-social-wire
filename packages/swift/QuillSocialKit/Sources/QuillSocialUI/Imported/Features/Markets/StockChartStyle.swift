#if os(iOS)
enum StockChartStyle: String, CaseIterable, Identifiable, Sendable {
    case line
    case candlesticks

    var id: Self { self }
    var title: String {
        switch self {
        case .line: "Line"
        case .candlesticks: "Candlesticks"
        }
    }

    // TradingView's hosted Advanced Chart uses the same series IDs as its chart library.
    var tradingViewValue: String {
        switch self {
        case .line: "2"
        case .candlesticks: "1"
        }
    }
}

#endif
