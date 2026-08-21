import Testing
@testable import AppView

@Suite("The Wire remote corpus configuration")
struct WireCorpusRemoteConfigTests {
  private let remote = [
    "APP_ENV": "dev",
    "WIRE_CORPUS_EDGE_BASE_URL": "https://wire-corpus.example.test",
    "WIRE_CORPUS_EDGE_SERVICE_ID": "development-appview",
    "WIRE_CORPUS_EDGE_HMAC_SECRET": String(repeating: "h", count: 32),
  ]

  @Test("accepts an exact HTTPS origin and dedicated identity")
  func valid() throws {
    let parsed = try WireCorpusRemoteConfig.fromEnvironment(remote)
    let config = try #require(parsed)
    #expect(config.baseURL == "https://wire-corpus.example.test")
    #expect(config.serviceID == "development-appview")
  }

  @Test("rejects partial, credentialed, and insecure hosted configuration")
  func invalid() {
    #expect(throws: WireDiscoveryConfigError.incompleteCorpusEdgeConfiguration) {
      _ = try WireCorpusRemoteConfig.fromEnvironment([
        "WIRE_CORPUS_EDGE_BASE_URL": "https://wire-corpus.example.test"
      ])
    }
    var credentialed = remote
    credentialed["WIRE_CORPUS_EDGE_BASE_URL"] = "https://user:pass@wire-corpus.example.test"
    #expect(throws: WireDiscoveryConfigError.invalidCorpusEdgeBaseURL) {
      _ = try WireCorpusRemoteConfig.fromEnvironment(credentialed)
    }
    var insecure = remote
    insecure["WIRE_CORPUS_EDGE_BASE_URL"] = "http://wire-corpus.example.test"
    #expect(throws: WireDiscoveryConfigError.invalidCorpusEdgeBaseURL) {
      _ = try WireCorpusRemoteConfig.fromEnvironment(insecure)
    }
  }

  @Test("Production AppView keeps the canonical local PostgreSQL store")
  func productionRejectsRemoteCorpusConfiguration() {
    var production = remote
    production["APP_ENV"] = "prod"
    production["DATABASE_URL"] = "postgresql://production-private"
    production["WIRE_FEED_MODE"] = "api"
    production["WIRE_CURSOR_HMAC_SECRET"] = String(repeating: "c", count: 32)
    #expect(throws: WireDiscoveryConfigError.remoteCorpusEdgeNotAllowedInProduction) {
      _ = try AppViewServiceConfig.fromEnvironment(production)
    }
  }

  @Test("Development API mode cannot fall back to Development corpus tables")
  func developmentRequiresRemoteCorpusConfiguration() {
    #expect(throws: WireDiscoveryConfigError.missingCorpusEdgeForDevelopment) {
      _ = try AppViewServiceConfig.fromEnvironment([
        "APP_ENV": "dev",
        "DATABASE_URL": "postgresql://development-private",
        "WIRE_FEED_MODE": "api",
        "WIRE_CURSOR_HMAC_SECRET": String(repeating: "c", count: 32),
      ])
    }
  }
}
