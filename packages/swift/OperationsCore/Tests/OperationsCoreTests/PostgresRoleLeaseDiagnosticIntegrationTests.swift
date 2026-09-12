import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite("PostgreSQL lease diagnostics", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
  "Requires an explicitly disposable migrated PostgreSQL database."))
struct PostgresRoleLeaseDiagnosticIntegrationTests {
  @Test("snapshot scopes the lease and emits wait/blocker metadata without SQL text")
  func scopedSnapshot() async throws {
    try await withPools { control, diagnostic, logger in
      let role = "diagnostic.\(UUID().uuidString)"
      let store = PostgresOperationsStore(pool: control, environment: "dev", logger: logger)
      let at = Date()
      _ = try await store.acquireRoleLease(role: role, ownerID: "owner-one",
        leaseUntil: at.addingTimeInterval(60), at: at)
      let other = PostgresOperationsStore(pool: control, environment: "prod", logger: logger)
      _ = try await other.acquireRoleLease(role: role, ownerID: "owner-other",
        leaseUntil: at.addingTimeInterval(60), at: at)
      let recorder = LeaseDiagnosticTestRecorder()
      let sampler = PostgresRoleLeaseDiagnosticSampler(pool: diagnostic, environment: "dev", logger: recorder.logger)
      var waiter: Task<Void, any Error>?
      defer { waiter?.cancel() }
      try await control.withTransaction(logger: logger) { blocker in
        try await blocker.query(
          "SELECT 1 FROM operations_role_leases WHERE environment = 'dev' AND role = \(role) FOR UPDATE",
          logger: logger)
        waiter = Task {
          let rows = try await control.query(
            """
            /* private_sql_parameter */ SELECT 1 FROM operations_role_leases
            WHERE environment = 'dev' AND role = \(role) FOR UPDATE
            """, logger: logger)
          for try await _ in rows {}
        }
        // Wait until a real backend is blocked. The probe selects only aggregate state,
        // never query text or bound values, matching the production diagnostic policy.
        var blocked = false
        for _ in 0..<100 {
          let rows = try await control.query(
            "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock')",
            logger: logger)
          for try await row in rows { blocked = try row.decode(Bool.self) }
          if blocked { break }
          try await Task.sleep(for: .milliseconds(10))
        }
        try #require(blocked)
        await sampler.capture(role: role)
        let record = try #require(recorder.entries.first)
        #expect(record["availability"] == "available")
        #expect(record["owner_id"] == "owner-one")
        #expect(record["fencing_token"] == "1")
        #expect(record["environment"] == "dev" && record["role"] == role)
        #expect(record["database_time"] != nil && record["process_time"] != nil)
        #expect(record["backends"]?.contains("Lock") == true)
        #expect(record["backends"]?.contains("blocking_pids") == true)
        #expect(!String(describing: record).contains("private_sql_parameter"))
        #expect(!String(describing: record).contains("owner-other"))
      }
      try await waiter?.value
    }
  }

  @Test("relation lock waits use 500ms and local diagnostic settings do not leak")
  func boundedLockWait() async throws {
    try await withPools { control, diagnostic, logger in
      let recorder = LeaseDiagnosticTestRecorder()
      let sampler = PostgresRoleLeaseDiagnosticSampler(pool: diagnostic, environment: "dev", logger: recorder.logger)
      try await control.withTransaction(logger: logger) { blocker in
        try await blocker.query("LOCK TABLE operations_role_leases IN ACCESS EXCLUSIVE MODE", logger: logger)
        let started = ContinuousClock.now
        await sampler.capture(role: "diagnostic.lock")
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(recorder.entries.first?["availability"] == "unavailable")
        #expect(recorder.entries.first?["failure"] == "lockTimeout")
      }
      let settings = try await diagnostic.query(
        "SELECT current_setting('statement_timeout'), current_setting('lock_timeout'), current_setting('transaction_read_only')",
        logger: logger)
      for try await row in settings {
        let value = try row.decode((String, String, String).self)
        #expect(value.0 == "0" && value.1 == "0" && value.2 == "off")
      }
    }
  }

  @Test("pool acquisition is included in the 3s diagnostic deadline")
  func boundedPoolWait() async throws {
    try await withPools { _, diagnostic, _ in
      let recorder = LeaseDiagnosticTestRecorder()
      let sampler = PostgresRoleLeaseDiagnosticSampler(pool: diagnostic, environment: "dev", logger: recorder.logger)
      try await diagnostic.withConnection { _ in
        let started = ContinuousClock.now
        await sampler.capture(role: "diagnostic.pool")
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(recorder.entries.first?["failure"] == "operationTimedOut")
      }
      // A timed-out queued diagnostic never owns or retires the other borrower's connection.
      let logger = Logger(label: "diagnostic-noop", factory: { _ in SwiftLogNoOpLogHandler() })
      let rows = try await diagnostic.query("SELECT 1", logger: logger)
      for try await row in rows { #expect(try row.decode(Int.self) == 1) }
    }
  }

  private func withPools(
    _ body: (PostgresClient, PostgresClient, Logger) async throws -> Void
  ) async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: raw))
    let logger = Logger(label: "diagnostic-noop", factory: { _ in SwiftLogNoOpLogHandler() })
    var config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.minimumConnections = 0
    config.options.maximumConnections = 4
    let control = PostgresClient(configuration: config, backgroundLogger: logger)
    config.options.maximumConnections = 1
    let diagnostic = PostgresClient(configuration: config, backgroundLogger: logger)
    let controlTask = Task { await control.run() }
    let diagnosticTask = Task { await diagnostic.run() }
    defer { controlTask.cancel(); diagnosticTask.cancel() }
    try await body(control, diagnostic, logger)
  }
}
