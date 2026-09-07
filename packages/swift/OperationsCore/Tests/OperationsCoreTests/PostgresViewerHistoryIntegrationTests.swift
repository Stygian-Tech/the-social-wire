import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite(
  "Operations PostgreSQL daily viewer history",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."
  )
)
struct PostgresViewerHistoryIntegrationTests {
  @Test("UTC daily samples retain the newest observation, preserve gaps and isolate environments")
  func dailyObservations() async throws {
    try await withStore { store, pool, logger in
      let midnight = Date(timeIntervalSince1970: 1_788_739_200) // UTC midnight.
      let early = OperationsViewerCounts(
        knownViewers: 10, activeViewers7d: 2, activeViewers30d: 5,
        observedAt: midnight.addingTimeInterval(60))
      let late = OperationsViewerCounts(
        knownViewers: 12, activeViewers7d: 3, activeViewers30d: 6,
        observedAt: midnight.addingTimeInterval(86_399))
      let next = OperationsViewerCounts(
        knownViewers: 13, activeViewers7d: 4, activeViewers30d: 7,
        observedAt: midnight.addingTimeInterval(3 * 86_400))
      #expect(try await store.fetchViewerHistory(at: midnight).isEmpty)
      try await store.saveViewerHistory(late)
      try await store.saveViewerHistory(early) // A delayed collector cannot regress today's sample.
      try await store.saveViewerHistory(next)
      let other = PostgresOperationsStore(
        pool: pool, environment: store.environment + "-other", logger: logger)
      #expect(try await other.fetchViewerHistory(at: next.observedAt).isEmpty)
      let history = try await store.fetchViewerHistory(at: next.observedAt)
      #expect(history == [late, next])
      let overview = try await store.overview(at: next.observedAt)
      #expect(overview.viewerHistory == history)
      let decoded = try JSONDecoder().decode(
        OperationsOverview.self, from: JSONEncoder().encode(overview))
      #expect(decoded.viewerHistory == history)
    }
  }

  @Test("retention includes exactly 90 UTC dates and persists without synthesizing missing history")
  func retention() async throws {
    try await withStore { store, pool, logger in
      let midnight = Date(timeIntervalSince1970: 1_788_739_200)
      let now = midnight.addingTimeInterval(1)
      for daysAgo in 0..<92 {
        try await store.saveViewerHistory(OperationsViewerCounts(
          knownViewers: 100, activeViewers7d: 10, activeViewers30d: 30,
          observedAt: midnight.addingTimeInterval(Double(-daysAgo * 86_400))))
      }
      #expect(try await store.fetchViewerHistory(at: now).count == 90)
      try await store.recordViewerHistory(at: now)
      let history = try await store.fetchViewerHistory(at: now)
      #expect(history.count == 90)
      #expect(history.first?.observedAt == midnight.addingTimeInterval(-89 * 86_400))
      #expect(history.last?.observedAt == now)
      let restarted = PostgresOperationsStore(
        pool: pool, environment: store.environment, logger: logger)
      #expect(try await restarted.fetchViewerHistory(at: now) == history)
      let rows = try await pool.query(
        "SELECT COUNT(*)::bigint FROM operations_viewer_daily_counts WHERE environment = \(store.environment)",
        logger: logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 90) }
    }
  }

  @Test("viewer observation queries time out without poisoning a pooled connection")
  func boundedObservation() async throws {
    try await withStore { store, pool, logger in
      let started = ContinuousClock.now
      await #expect(throws: (any Error).self) {
        _ = try await store.viewerHistoryRows("SELECT pg_sleep(10)")
      }
      #expect(started.duration(to: .now) < .seconds(8))
      try await store.ping()
      let rows = try await pool.query("SHOW statement_timeout", logger: logger)
      for try await row in rows { #expect(try row.decode(String.self) == "0") }
    }
  }

  @Test("an unavailable projection observation leaves a gap instead of recording zero viewers")
  func unavailableObservation() async throws {
    try await withStore { store, pool, logger in
      let now = Date()
      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query(
          "LOCK TABLE appview_viewer_feeds IN ACCESS EXCLUSIVE MODE", logger: logger)
        await #expect(throws: (any Error).self) {
          try await store.recordViewerHistory(at: now)
        }
      }
      #expect(try await store.fetchViewerHistory(at: now).isEmpty)
    }
  }

  private func withStore(
    _ body: (PostgresOperationsStore, PostgresClient, Logger) async throws -> Void
  ) async throws {
    let rawURL = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: rawURL))
    let logger = Logger(label: "operations-viewer-history.tests")
    var config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 4
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let environment = "viewer-history-test-\(UUID().uuidString)"
    let store = PostgresOperationsStore(pool: pool, environment: environment, logger: logger)
    do {
      try await body(store, pool, logger)
    } catch {
      _ = try? await pool.query(
        "DELETE FROM operations_viewer_daily_counts WHERE environment = \(environment)",
        logger: logger)
      throw error
    }
    try await pool.query(
      "DELETE FROM operations_viewer_daily_counts WHERE environment = \(environment)",
      logger: logger)
  }
}
