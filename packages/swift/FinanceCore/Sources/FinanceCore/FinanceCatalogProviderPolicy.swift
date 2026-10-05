/// Provider activation is independent of feed visibility and never establishes an entitlement.
public struct FinanceCatalogProviderPolicy: Sendable {
  public let cryptoEnabled: Bool
  public let reviewedCryptoEnabled: Bool
  public init(environment: [String: String]) {
    reviewedCryptoEnabled = environment["FINANCE_REVIEWED_CRYPTO_CATALOG_ENABLED"]?.lowercased() == "true"
    cryptoEnabled = environment["FINANCE_CRYPTO_CATALOG_ENABLED"]?.lowercased() == "true"
  }
  public func permits(_ instrument: FinanceInstrument) -> Bool {
    guard instrument.kind.lowercased() == "crypto" else { return true }
    if FinanceReviewedAssets.referenceInstruments.contains(instrument) { return reviewedCryptoEnabled }
    return cryptoEnabled
  }
  public func filter(_ instruments: [FinanceInstrument]) -> [FinanceInstrument] {
    instruments.filter { permits($0) }
  }
  public var revision: String {
    let provider = cryptoEnabled ? "providers-crypto-v1" : "providers-reference-v1"
    return provider + (reviewedCryptoEnabled ? ":reviewed-crypto-v1" : "")
  }
}
