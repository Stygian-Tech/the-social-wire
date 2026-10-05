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

  @Test("supports explicit Development and Production with one dedicated service identity", arguments: ["dev", "prod"])
  func hostedEnvironment(appEnvironment: String) throws {
    var environment = base
    environment["APP_ENV"] = appEnvironment
    let config = try WireCorpusEdgeConfig.load(environment)
    #expect(config.allowedServiceID == "development-appview")
    #expect(config.maximumConnections == 4)

  }

  @Test("rejects unspecified and unsupported environments", arguments: [nil, "", "local", "production", "staging"] as [String?])
  func rejectsOtherEnvironments(appEnvironment: String?) {
    var environment = base
    environment["APP_ENV"] = appEnvironment
    #expect(throws: WireCorpusEdgeConfigError.unsupportedEnvironment) {
      _ = try WireCorpusEdgeConfig.load(environment)
    }
  }

  @Test("allows a single connection for rolling deployments within a restricted role budget", arguments: [(1, 1), (0, 1), (-1, 1), (2, 2), (8, 8), (99, 8)])
  func boundedConnectionBudget(requested: Int, expected: Int) throws {
    var environment = base
    environment["APP_ENV"] = "dev"
    environment["WIRE_CORPUS_EDGE_POSTGRES_MAX_CONNECTIONS"] = String(requested)
    #expect(try WireCorpusEdgeConfig.load(environment).maximumConnections == expected)
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
