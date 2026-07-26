import Testing

@testable import ThinAppViewCore

@Suite("Thin AppView database environment")
struct DatabaseBackendTests {
  @Test("explicit local development uses SQLite")
  func localSQLite() throws {
    let backend = try DatabaseBackend.fromEnvironment([
      "APP_ENV": "local",
      "SQLITE_DB_PATH": "/tmp/test.sqlite",
    ])
    guard case .sqlite(let path) = backend else {
      Issue.record("Expected SQLite")
      return
    }
    #expect(path == "/tmp/test.sqlite")
  }

  @Test("worker refuses an unscoped environment even without Tap")
  func workerRequiresEnvironment() {
    #expect(throws: DatabaseBackendConfigurationError.missingAppEnvironment) {
      try DatabaseBackend.fromEnvironment([:])
    }
  }

  @Test("worker refuses unknown environment keys")
  func workerRejectsUnknownEnvironment() {
    #expect(throws: DatabaseBackendConfigurationError.invalidAppEnvironment("staging")) {
      try DatabaseBackend.fromEnvironment(["APP_ENV": "staging"])
    }
  }

  @Test("deployed worker refuses an unscoped environment")
  func deployedWorkerRequiresEnvironment() {
    #expect(throws: DatabaseBackendConfigurationError.missingAppEnvironment) {
      try DatabaseBackend.fromEnvironment(["FLY_APP_NAME": "worker"])
    }
  }

  @Test("non-local environment requires its durable database")
  func nonLocalRequiresDatabaseURL() {
    #expect(
      throws: DatabaseBackendConfigurationError.missingDatabaseURL(environment: "dev")
    ) {
      try DatabaseBackend.fromEnvironment(["APP_ENV": "dev"])
    }
  }

  @Test("environment-scoped Postgres is accepted")
  func environmentScopedPostgres() throws {
    let url = "postgresql://example.invalid/database"
    let backend = try DatabaseBackend.fromEnvironment([
      "APP_ENV": "prod",
      "SUPABASE_DATABASE_URL": url,
    ])
    guard case .postgres(let configuredURL) = backend else {
      Issue.record("Expected Postgres")
      return
    }
    #expect(configuredURL == url)
  }
}
