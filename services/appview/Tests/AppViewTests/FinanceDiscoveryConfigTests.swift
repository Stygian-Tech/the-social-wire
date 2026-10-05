import FinanceCore
import Foundation
import Testing
@testable import AppView

@Suite("Finance discovery configuration")
struct FinanceDiscoveryConfigTests {
  @Test("Finance and external widgets default off without entitlement evidence")
  func defaults() throws {
    let config = try FinanceDiscoveryConfig.fromEnvironment([:])
    #expect(config.mode == .off)
    #expect(!config.mode.canServeAPI)
    #expect(!config.widgetsEnabled)
    #expect(!config.catalogRightsConfirmed)
    #expect(config.cursorSecret == nil)
  }

  @Test("mode, widget display and catalog rights are independent")
  func independentGates() throws {
    let secret = String(repeating: "f", count: 32)
    let api = try FinanceDiscoveryConfig.fromEnvironment([
      "FINANCE_FEED_MODE": "api", "WIRE_CURSOR_HMAC_SECRET": secret,
      "FINANCE_WIDGETS_ENABLED": "true"
    ])
    #expect(api.mode.canServeAPI)
    #expect(api.cursorSecret == secret)
    #expect(api.widgetsEnabled)
    #expect(!api.catalogRightsConfirmed)
    let visible = try FinanceDiscoveryConfig.fromEnvironment([
      "FINANCE_FEED_MODE": "visible", "WIRE_CURSOR_HMAC_SECRET": "wire-secret",
      "FINANCE_CURSOR_HMAC_SECRET": secret, "FINANCE_CATALOG_RIGHTS_CONFIRMED": "TRUE"
    ])
    #expect(visible.cursorSecret == secret)
    #expect(visible.catalogRightsConfirmed)
    #expect(!visible.widgetsEnabled)
    #expect(try FinanceDiscoveryConfig.fromEnvironment(["FINANCE_FEED_MODE": "shadow"]).mode.canServeAPI == false)
  }

  @Test("invalid modes fail closed instead of accidentally activating Finance")
  func invalidMode() {
    #expect(throws: (any Error).self) {
      try FinanceDiscoveryConfig.fromEnvironment(["FINANCE_FEED_MODE": "enabled"])
    }
  }

  @Test("Finance corpus override is isolated and requires complete authenticated configuration")
  func financeCorpusOverride() throws {
    let environment = ["APP_ENV": "dev", "FINANCE_CORPUS_EDGE_BASE_URL": "https://finance-dev.example",
      "FINANCE_CORPUS_EDGE_SERVICE_ID": "finance-dev", "FINANCE_CORPUS_EDGE_HMAC_SECRET": String(repeating: "s", count: 32),
      "WIRE_CORPUS_EDGE_BASE_URL": "https://wire-prod.example"]
    let config = try FinanceDiscoveryConfig.fromEnvironment(environment)
    #expect(config.corpusEdge?.baseURL == "https://finance-dev.example")
    #expect(config.corpusEdge?.serviceID == "finance-dev")
    #expect(try FinanceDiscoveryConfig.fromEnvironment([:]).corpusEdge == nil)
    #expect(throws: (any Error).self) {
      try FinanceDiscoveryConfig.fromEnvironment(["FINANCE_CORPUS_EDGE_BASE_URL": "https://finance-dev.example"])
    }
    let privateConfig = try FinanceDiscoveryConfig.fromEnvironment(environment.merging(
      ["FINANCE_CORPUS_EDGE_BASE_URL": "http://finance.railway.internal:8080"], uniquingKeysWith: { _, new in new }))
    #expect(privateConfig.corpusEdge?.baseURL == "http://finance.railway.internal:8080")
  }

  @Test("language normalization retains exact primary language and rejects malformed input")
  func languages() {
    #expect(PostgresFinanceFeedStore.language("en-US") == "en")
    #expect(PostgresFinanceFeedStore.language("FR-ca") == "fr")
    #expect(PostgresFinanceFeedStore.language(nil) == "und")
    for invalid in ["e", "123", "../../../", "verylonglanguage", "éé"] {
      #expect(PostgresFinanceFeedStore.language(invalid) == "und")
    }
  }
}

@Test("Finance crypto catalog remains off independently of feed rights and visibility")
func financeCryptoCatalogConfigGate() throws {
  let base = ["FINANCE_FEED_MODE": "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true"]
  #expect(try FinanceDiscoveryConfig.fromEnvironment(base).providerPolicy.cryptoEnabled == false)
  #expect(try FinanceDiscoveryConfig.fromEnvironment(base.merging(["FINANCE_CRYPTO_CATALOG_ENABLED": "true"], uniquingKeysWith: { _, new in new })).providerPolicy.cryptoEnabled)
}
