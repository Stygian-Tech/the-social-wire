import Testing
@testable import FinanceCore

struct FinanceCatalogProviderPolicyTests {
  @Test("crypto requires independent activation and retained provider metadata stays hidden")
  func providerGate() {
    let crypto = FinanceInstrument(id: "coin", name: "Bitcoin", symbol: "BTC", kind: "crypto", providerID: "bitcoin")
    let stock = FinanceInstrument(id: "stock", name: "Apple", symbol: "AAPL", kind: "Common Stock", providerID: "BBG000B9Y5X2")
    let defaultPolicy = FinanceCatalogProviderPolicy(environment: ["FINANCE_CATALOG_RIGHTS_CONFIRMED": "true"])
    #expect(defaultPolicy.filter([crypto, stock]).map(\.id) == ["stock"])
    let enabled = FinanceCatalogProviderPolicy(environment: ["FINANCE_CRYPTO_CATALOG_ENABLED": "true"])
    #expect(enabled.filter([crypto, stock]).count == 2)
    #expect(enabled.revision != defaultPolicy.revision)
  }
}
