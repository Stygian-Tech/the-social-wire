import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite("PostgreSQL inbox census bounds", .enabled(
  if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil))
struct PostgresIngestionCensusBudgetTests {
  private let logger = Logger(label: "inbox-census-budget.tests")

  @Test("blocked census is unavailable and the next pooled session has default timeouts")
  func blockedCensusAndReuse() async throws {
    try await withFixture { pool, store in
      let locked = CensusGate()
      let release = CensusGate()
      let blocker = Task {
        try await pool.withTransaction(logger: logger) { connection in
          try await connection.query("LOCK TABLE appview_ingestion_inbox IN ACCESS EXCLUSIVE MODE", logger: logger)
          await locked.open()
          await release.wait()
        }
      }
      await locked.wait()
      let start = ContinuousClock.now
      do {
        _ = try await store.loadIngestionInboxMetrics()
        Issue.record("Unavailable census must throw instead of returning zero")
      } catch { #expect(RoleLeaseFailure.classify(error) == .lockTimeout) }
      #expect(start.duration(to: .now) < .seconds(3))
      await release.open()
      try await blocker.value
      let rows = try await pool.query("SELECT current_setting('statement_timeout'), current_setting('lock_timeout')", logger: logger)
      for try await row in rows {
        let values = try row.decode((String, String).self)
        #expect(values.0 == "0" && values.1 == "0")
      }
      #expect(try await store.loadIngestionInboxMetrics().isEmpty)
    }
  }

  @Test("cancellation retires a census observed waiting on a database lock")
  func cancellationAfterQuerySubmission() async throws {
    try await withFixture { pool, store in
      try await pool.withTransaction(logger: logger) { blocker in
        try await blocker.query("LOCK TABLE appview_ingestion_inbox IN ACCESS EXCLUSIVE MODE", logger: logger)
        let census = Task { try await store.loadIngestionInboxMetrics() }
        defer { census.cancel() }
        var waiting = false
        for _ in 0..<50 {
          try await blocker.query("SELECT pg_stat_clear_snapshot()", logger: logger)
          let rows = try await blocker.query("""
            SELECT EXISTS (SELECT 1 FROM pg_stat_activity
              WHERE application_name = current_setting('application_name')
                AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'
                AND query LIKE '%GROUP BY source_generation%')
            """, logger: logger)
          for try await row in rows { waiting = try row.decode(Bool.self) }
          if waiting { break }
          try await Task.sleep(for: .milliseconds(5))
        }
        census.cancel()
        do {
          _ = try await census.value
          Issue.record("Cancelled submitted census must not produce an observation")
        } catch { #expect(RoleLeaseFailure.classify(error) == .cancelled) }
        #expect(waiting, "Cancellation must occur after PostgreSQL observes the census query")
      }
      #expect(try await store.loadIngestionInboxMetrics().isEmpty)
    }
  }

  @Test("pool starvation is included in the census overall deadline")
  func poolDeadline() async throws {
    try await withFixture(maximumConnections: 1) { pool, store in
      try await pool.withConnection { _ in
        let started = ContinuousClock.now
        do {
          _ = try await store.loadIngestionInboxMetrics()
          Issue.record("Unavailable pool must not produce an observation")
        } catch { #expect(RoleLeaseFailure.classify(error) == .operationTimedOut) }
        #expect(started.duration(to: .now) < .seconds(5))
      }
      #expect(try await store.loadIngestionInboxMetrics().isEmpty)
    }
  }

  @Test("bounded census preserves exact actionable and retained historical counts")
  func retainedHistoryFixture() async throws {
    try await withFixture { pool, store in
      // Synthetic correctness fixture, not production-sized workload or capacity evidence.
      try await pool.query("""
        INSERT INTO appview_ingestion_inbox
          (environment, source_generation, status, staged_at, payload)
        SELECT 'dev', CASE WHEN n <= 100 THEN 'active' ELSE 'history' END,
          CASE WHEN n <= 100 THEN 'pending' ELSE 'applied' END,
          clock_timestamp() - INTERVAL '1 minute', repeat('x', 1024)
        FROM generate_series(1, 50000) n
        """, logger: logger)
      let started = ContinuousClock.now
      let census = try await store.loadIngestionInboxMetrics()
      #expect(census["active"]?.pending == 100)
      #expect(census["history"]?.applied == 49_900)
      #expect(census["history"]?.total == 49_900)
      print("Synthetic 50000-row inbox census elapsed: \(started.duration(to: .now)); not capacity evidence")
    }
  }

  private func withFixture(
    maximumConnections: Int = 2,
    body: (PostgresClient, PostgresOperationsStore) async throws -> Void
  ) async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: raw))
    let schema = "census_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var configuration = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    configuration.options.maximumConnections = maximumConnections
    configuration.options.additionalStartupParameters = [("search_path", schema), ("application_name", schema)]
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runner = Task { await pool.run() }
    defer { runner.cancel() }
    // The identifier is generated solely from a fixed prefix and UUID hex digits.
    try await pool.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"), logger: logger)
    do {
      try await pool.query("""
        CREATE TABLE appview_ingestion_inbox (
          environment text NOT NULL, source_generation text NOT NULL, status text NOT NULL,
          staged_at timestamptz NOT NULL, reconciled_at timestamptz, payload text)
        """, logger: logger)
      try await body(pool, PostgresOperationsStore(pool: pool, environment: "dev", logger: logger))
    } catch {
      _ = try? await pool.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"), logger: logger)
      throw error
    }
    try await pool.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"), logger: logger)
  }
}

private actor CensusGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
  func open() { opened = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
