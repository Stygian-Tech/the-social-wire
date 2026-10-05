/// Provider activation is independent of feed visibility and never establishes an entitlement.
public struct FinanceCatalogProviderPolicy: Sendable {
  public let cryptoEnabled: Bool
  public init(environment: [String: String]) {
    cryptoEnabled = environment["FINANCE_CRYPTO_CATALOG_ENABLED"]?.lowercased() == "true"
  }
  public func permits(_ instrument: FinanceInstrument) -> Bool {
    cryptoEnabled || instrument.kind.lowercased() != "crypto"
  }
  public func filter(_ instruments: [FinanceInstrument]) -> [FinanceInstrument] {
    instruments.filter { permits($0) }
  }
  public var revision: String { cryptoEnabled ? "providers-crypto-v1" : "providers-reference-v1" }
}
