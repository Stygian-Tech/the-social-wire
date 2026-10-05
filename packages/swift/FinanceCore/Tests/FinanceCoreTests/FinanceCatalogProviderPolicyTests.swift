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

@Test("reviewed crypto activation permits only exact local references without activating CoinGecko")
func reviewedCryptoGate() {
  let references = FinanceReviewedAssets.referenceInstruments.filter { $0.kind == "crypto" }
  let policy = FinanceCatalogProviderPolicy(environment: ["FINANCE_REVIEWED_CRYPTO_CATALOG_ENABLED": "true"])
  #expect(!policy.cryptoEnabled)
  #expect(policy.reviewedCryptoEnabled)
  #expect(policy.filter(references).count == 2)
  let providerBitcoin = FinanceInstrument(id: FinanceIdentity.instrumentID(provider: "coingecko", nativeID: "bitcoin"),
    name: "Bitcoin", symbol: "BTC", kind: "crypto", providerID: "bitcoin")
  #expect(!policy.permits(providerBitcoin))
  let counterfeit = FinanceInstrument(id: references[0].id, name: "Different Asset", symbol: "BTC", kind: "crypto", providerID: references[0].providerID)
  #expect(!policy.permits(counterfeit))
  let defaultPolicy = FinanceCatalogProviderPolicy(environment: [:])
  #expect(defaultPolicy.filter(references).isEmpty)
  #expect(policy.revision != defaultPolicy.revision)
}
