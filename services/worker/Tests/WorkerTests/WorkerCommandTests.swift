import Testing
import ThinAppViewCore

@testable import Worker

@Suite("WorkerCommand environment")
struct WorkerCommandTests {
  @Test("Thin AppView disabled yields descriptive runtime error")
  func thinAppViewDisabledError() {
    let error = WorkerRuntimeError.thinAppViewDisabled
    #expect(error.description.contains("ENABLE_THIN_APPVIEW"))
  }

  @Test("ThinAppViewConfig respects ENABLE_THIN_APPVIEW")
  func configEnabledFlag() {
    let disabled = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "false"])
    #expect(disabled.enabled == false)

    let enabled = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    #expect(enabled.enabled == true)
  }

  @Test("ThinAppViewConfig parses custom relay and TTL env")
  func configCustomValues() {
    let cfg = ThinAppViewConfig.fromEnvironment([
      "ENABLE_THIN_APPVIEW": "true",
      "THIN_APPVIEW_RELAY_WS_URL": "wss://relay.example/subscribe",
      "THIN_APPVIEW_CONTENT_TTL_SECONDS": "3600",
      "THIN_APPVIEW_READ_MARK_TTL_SECONDS": "7200",
      "THIN_APPVIEW_MAX_ENROLL_AUTHORS": "42",
    ])
    #expect(cfg.relayWebSocketURL == "wss://relay.example/subscribe")
    #expect(cfg.contentRetentionSeconds == 3600)
    #expect(cfg.readMarkRetentionSeconds == 7200)
    #expect(cfg.maxEnrollAuthors == 42)
  }

  @Test("DatabaseBackend uses SQLite path in local APP_ENV")
  func sqliteBackendLocal() {
    let backend = DatabaseBackend.fromEnvironment([
      "APP_ENV": "local",
      "SQLITE_DB_PATH": "/tmp/worker-test.sqlite",
    ])
    if case .sqlite(let path) = backend {
      #expect(path == "/tmp/worker-test.sqlite")
    } else {
      Issue.record("Expected sqlite backend")
    }
  }

  @Test("RuntimeEnvironment merges dotenv with process precedence")
  func dotenvMergePrecedence() {
    let fromFile = RuntimeEnvironment.parseDotenv(
      """
      ENABLE_THIN_APPVIEW=true
      # comment
      APP_ENV=local
      """
    )
    let merged = RuntimeEnvironment.mergeDotenvFile(
      fromFile,
      into: ["ENABLE_THIN_APPVIEW": "false", "APP_ENV": "local"]
    )
    #expect(merged["ENABLE_THIN_APPVIEW"] == "false")
    #expect(merged["APP_ENV"] == "local")
  }
}
