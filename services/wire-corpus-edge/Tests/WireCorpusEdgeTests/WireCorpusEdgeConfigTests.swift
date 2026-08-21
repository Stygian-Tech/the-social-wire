import Testing
@testable import WireCorpusEdge

@Suite("The Wire Corpus Edge configuration")
struct WireCorpusEdgeConfigTests {
  private let base = [
    "APP_ENV": "prod",
    "DATABASE_URL": "postgresql://wire@postgres.railway.internal:5432/railway",
    "WIRE_CORPUS_EDGE_SHARED_SECRET": String(repeating: "s", count: 32),
    "WIRE_CORPUS_EDGE_ALLOWED_SERVICE_ID": "development-appview",
  ]

  @Test("is production only and binds one dedicated service identity")
  func productionOnly() throws {
    let config = try WireCorpusEdgeConfig.load(base)
    #expect(config.allowedServiceID == "development-appview")
    #expect(config.maximumConnections == 4)

    var development = base
    development["APP_ENV"] = "dev"
    #expect(throws: WireCorpusEdgeConfigError.productionOnly) {
      _ = try WireCorpusEdgeConfig.load(development)
    }
  }

  @Test("requires strong dedicated trust material")
  func trustValidation() {
    var shortSecret = base
    shortSecret["WIRE_CORPUS_EDGE_SHARED_SECRET"] = "short"
    #expect(throws: WireCorpusEdgeConfigError.invalidSharedSecret) {
      _ = try WireCorpusEdgeConfig.load(shortSecret)
    }

    var invalidID = base
    invalidID["WIRE_CORPUS_EDGE_ALLOWED_SERVICE_ID"] = "did/viewer"
    #expect(throws: WireCorpusEdgeConfigError.invalidAllowedServiceID) {
      _ = try WireCorpusEdgeConfig.load(invalidID)
    }
  }
}
