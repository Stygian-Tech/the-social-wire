import Foundation

public enum FinanceAssetKind {
  public static func classify(_ instrument: FinanceInstrument) -> String {
    switch instrument.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "etf": return "etf"
    case "crypto": return "crypto"
    case "index": return "index"
    case "commodity": return "commodity"
    default: return "stock"
    }
  }

  /// Excludes substantive crypto reporting even when the reference provider is unavailable.
  public static func isCryptoStory(title: String, summary: String?, analysis: FinanceArticleAnalysis,
    catalog: [FinanceInstrument]) -> Bool {
    let cryptoIDs = Set(catalog.filter { classify($0) == "crypto" }.map(\.id))
    if analysis.associations.contains(where: { cryptoIDs.contains($0.instrumentID) && $0.confidence.isFinite && (0.9...1).contains($0.confidence) && $0.resolverVersion == FinanceResolver.version }) { return true }
    let text = FinanceTopicEvidence(title: title, summary: summary).text
    return ["cryptocurrency", "cryptocurrencies", "crypto", "bitcoin", "ethereum", "stablecoin", "stablecoins"]
      .contains { FinanceTopicEvidence.contains($0, in: text) }
  }
}
