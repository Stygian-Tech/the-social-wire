/// Identity reference only; market display mappings and provider activation remain separately reviewed.
public enum FinanceReviewedAssets {
  // OpenFIGI v3 US TICKER mapping verified 2026-10-04. ETP identifies the wrapper;
  // these four sponsor-defined exchange-traded funds are reviewed as ETFs.
  public static let etfProviderIDs: Set<String> = ["BBG000BDTBL9", "BBG000BSWKH7", "BBG0015VYNT4", "BBG000BVZ4F5"]
  public static let referenceInstruments: [FinanceInstrument] = [
    // Official definitions: nasdaq.com/market-activity/index/ndx and spglobal.com/spdji/en/indices/equity/dow-jones-industrial-average/.
    .init(id: FinanceIdentity.instrumentID(provider: "reviewed", nativeID: "nasdaq100-index"),
      name: "Nasdaq 100", symbol: "NDX", kind: "index", providerID: "reviewed:nasdaq100-index", aliases: ["Nasdaq-100", "NASDAQ 100"]),
    .init(id: FinanceIdentity.instrumentID(provider: "reviewed", nativeID: "dow-jones-industrial-average"),
      name: "Dow Jones Industrial Average", symbol: "DJI", kind: "index", providerID: "reviewed:dow-jones-industrial-average", aliases: ["Dow Jones", "Dow industrials"]),
    // First-party project definitions, independently gated; no CoinGecko data or API activation.
    // Sources: bitcoin.org/en/bitcoin-for-individuals and ethereum.org/what-is-ether/.
    .init(id: FinanceIdentity.instrumentID(provider: "reviewed", nativeID: "bitcoin-asset"),
      name: "Bitcoin", symbol: "BTC", kind: "crypto", providerID: "reviewed:bitcoin-asset"),
    .init(id: FinanceIdentity.instrumentID(provider: "reviewed", nativeID: "ethereum-ether-asset"),
      name: "Ethereum", symbol: "ETH", kind: "crypto", providerID: "reviewed:ethereum-ether-asset")
  ]
}
