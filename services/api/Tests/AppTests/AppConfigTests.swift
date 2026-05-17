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

  @Test("OAUTH_PUBLIC_ORIGIN is nil when unset")
  func oauthOriginUnset() {
    let config = AppConfig.fromEnvironment([:])
    #expect(config.oauthPublicOrigin == nil)
  }

  @Test("OAUTH_PUBLIC_ORIGIN is trimmed when set")
  func oauthOriginSet() {
    let config = AppConfig.fromEnvironment([
      "OAUTH_PUBLIC_ORIGIN": "  https://tunnel.example  ",
    ])
    #expect(config.oauthPublicOrigin == "https://tunnel.example")
  }

  @Test("ENABLE_LEGACY_CONTENT_API defaults false")
  func legacyDiscoveryDefaultDisabled() {
    let config = AppConfig.fromEnvironment([:])
    #expect(config.enableLegacyContentAPI == false)
  }

  @Test("truthy ENABLE_LEGACY_CONTENT_API variants enable legacy gates")
  func legacyFlagTruthy() {
    for flag in ["1", "true", "YES", "on"] {
      let cfg = AppConfig.fromEnvironment(["ENABLE_LEGACY_CONTENT_API": flag])
      #expect(cfg.enableLegacyContentAPI == true)
    }
  }
}

