import Testing

@testable import ThinAppViewCore

@Suite("Postgres connection configuration")
struct PostgresConfigTests {
  @Test("Missing connection limit uses the shared-pool-safe default")
  func missingConnectionLimitUsesSafeDefault() {
    #expect(postgresMaximumConnections(environment: [:]) == 2)
  }

  @Test("Configured connection limit is honored")
  func configuredConnectionLimitIsHonored() {
    #expect(
      postgresMaximumConnections(
        environment: ["POSTGRES_MAX_CONNECTIONS": "5"]
      ) == 5
    )
  }

  @Test("Invalid connection limit uses the safe default")
  func invalidConnectionLimitUsesSafeDefault() {
    #expect(
      postgresMaximumConnections(
        environment: ["POSTGRES_MAX_CONNECTIONS": "not-a-number"]
      ) == 2
    )
  }

  @Test("Connection limit preserves one writer beside the authority fence")
  func connectionLimitPreservesFencedWriter() {
    #expect(
      postgresMaximumConnections(
        environment: ["POSTGRES_MAX_CONNECTIONS": "0"]
      ) == 2
    )
  }
  @Test("Connection labels use Railway service names and bounded safe fallbacks")
  func applicationName() {
    #expect(postgresApplicationName(fallback: "appview.worker", environment: [:]) == "appview.worker")
    #expect(postgresApplicationName(fallback: "worker", environment: ["RAILWAY_SERVICE_NAME": "App View"]) == "App-View")
    #expect(postgresApplicationName(fallback: "worker", environment: ["RAILWAY_SERVICE_NAME": "  "]) == "worker")
    #expect(postgresApplicationName(fallback: String(repeating: "x", count: 100), environment: [:]).utf8.count == 63)
    #expect(postgresApplicationName(fallback: "hello\nworld", environment: [:]) == "hello-world")
  }
}
