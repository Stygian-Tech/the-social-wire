import Foundation
import Testing

@testable import App

@Suite("AppConfig.fromEnvironment")
struct AppConfigTests {

  // MARK: - Local mode (SQLite)

  @Test("defaults to local/sqlite when APP_ENV is unset")
  func defaultsToLocal() {
    let config = AppConfig.fromEnvironment([:])
    #expect(config.appEnv == .local)
    if case .sqlite(let path) = config.cacheBackend {
      #expect(path == "./social-wire.sqlite")
    } else {
      Issue.record("Expected .sqlite backend, got \(config.cacheBackend)")
    }
  }

  @Test("local mode uses default SQLite path when SQLITE_DB_PATH is unset")
  func localDefaultSQLitePath() {
    let config = AppConfig.fromEnvironment(["APP_ENV": "local"])
    if case .sqlite(let path) = config.cacheBackend {
      #expect(path == "./social-wire.sqlite")
    } else {
      Issue.record("Expected .sqlite backend")
    }
  }

  @Test("local mode uses SQLITE_DB_PATH when set")
  func localUsesCustomSQLitePath() {
    let config = AppConfig.fromEnvironment([
      "APP_ENV": "local",
      "SQLITE_DB_PATH": "/data/sqlite/social-wire.sqlite",
    ])
    #expect(config.appEnv == .local)
    if case .sqlite(let path) = config.cacheBackend {
      #expect(path == "/data/sqlite/social-wire.sqlite")
    } else {
      Issue.record("Expected .sqlite backend")
    }
  }

  // MARK: - Dev/Prod mode (Postgres)

  @Test("dev mode uses SUPABASE_DATABASE_URL")
  func devModeUsesPostgres() {
    let url = "postgresql://postgres:pw@db.test.supabase.co:5432/postgres"
    let config = AppConfig.fromEnvironment([
      "APP_ENV": "dev",
      "SUPABASE_DATABASE_URL": url,
    ])
    #expect(config.appEnv == .dev)
    if case .postgres(let gotURL) = config.cacheBackend {
      #expect(gotURL == url)
    } else {
      Issue.record("Expected .postgres backend")
    }
  }

  @Test("prod mode uses SUPABASE_DATABASE_URL")
  func prodModeUsesPostgres() {
    let url = "postgresql://postgres:pw@db.test.supabase.co:5432/postgres"
    let config = AppConfig.fromEnvironment([
      "APP_ENV": "prod",
      "SUPABASE_DATABASE_URL": url,
    ])
    #expect(config.appEnv == .prod)
    if case .postgres(let gotURL) = config.cacheBackend {
      #expect(gotURL == url)
    } else {
      Issue.record("Expected .postgres backend")
    }
  }

  // MARK: - ATProto PLC URL

  @Test("uses default PLC URL when ATPROTO_PLC_URL is unset")
  func defaultPLCURL() {
    let config = AppConfig.fromEnvironment([:])
    #expect(config.atprotoPLCURL == "https://plc.directory")
  }

  @Test("uses custom PLC URL when ATPROTO_PLC_URL is set")
  func customPLCURL() {
    let config = AppConfig.fromEnvironment([
      "ATPROTO_PLC_URL": "https://plc.test.example",
    ])
    #expect(config.atprotoPLCURL == "https://plc.test.example")
  }

  // MARK: - Unknown APP_ENV falls back to local

  @Test("unrecognised APP_ENV falls back to local")
  func unknownAppEnvFallsBack() {
    let config = AppConfig.fromEnvironment(["APP_ENV": "staging"])
    #expect(config.appEnv == .local)
  }
}
