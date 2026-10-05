public enum FinanceReviewedCatalog {
  public static let version = "reviewed-v3"
  /// Reference fixtures only. Activation requires operator review of coverage and rights.
  public static let instruments: [FinanceInstrument] = [
    .init(id: FinanceIdentity.instrumentID(provider: "reviewed", nativeID: "sp500-index"),
      name: "S&P 500", symbol: "SPX", kind: "index", providerID: "reviewed:sp500-index", aliases: ["S&P500"]),
    .init(id: FinanceIdentity.instrumentID(provider: "reviewed", nativeID: "gold-spot-usd"),
      name: "Gold", symbol: "XAU", kind: "commodity", providerID: "reviewed:gold-spot-usd", currency: "USD")
  ] + FinanceReviewedAssets.referenceInstruments
}
