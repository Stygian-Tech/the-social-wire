/// A stock listing verified against the US exchange symbol directory.
public struct ResolvedStockTicker: Hashable, Sendable {
    public let ticker: String
    public let tradingViewSymbol: String

    public init(ticker: String, tradingViewSymbol: String) {
        self.ticker = ticker
        self.tradingViewSymbol = tradingViewSymbol
    }
}
