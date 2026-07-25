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

  @Test("Connection limit never falls below one")
  func connectionLimitNeverFallsBelowOne() {
    #expect(
      postgresMaximumConnections(
        environment: ["POSTGRES_MAX_CONNECTIONS": "0"]
      ) == 1
    )
  }
}
