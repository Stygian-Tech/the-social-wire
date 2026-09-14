import Foundation
import Logging
import PostgresNIO
import Testing
@testable import ThinAppViewCore

@Suite("Feed query deadline")
struct AppViewFeedQueryDeadlineTests {
  @Test("statement timeout consumes the original budget and never disables timeout")
  func remainingBudget() throws {
    let start = ContinuousClock.now
    let deadline = AppViewFeedQueryDeadline(startedAt: start)
    #expect(try deadline.statementMilliseconds(at: start) == 1975)
    #expect(try deadline.statementMilliseconds(at: start.advanced(by: .milliseconds(500))) == 1475)
    #expect(throws: AppViewFeedQueryDeadline.Failure.self) {
      try deadline.statementMilliseconds(at: start.advanced(by: .milliseconds(1975)))
    }
    #expect(throws: AppViewFeedQueryDeadline.Failure.self) {
      try deadline.check(at: start.advanced(by: .seconds(2)))
    }
  }
}

@Suite("Postgres feed query deadline", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil))
struct PostgresFeedQueryDeadlineTests {
  private let logger = Logger(label: "feed-deadline.tests")

  @Test("server statement cancellation retires the connection and leaves pool settings unchanged")
  func delayedStatement() async throws {
    try await withPool { pool in
      let start = ContinuousClock.now
      do {
        _ = try await AppViewFeedQueryDeadline.$current.withValue(.init(duration: .milliseconds(300))) {
          try await PostgresFeedQueryExecutor.query("SELECT pg_sleep(5)", pool: pool, logger: logger)
        }
        Issue.record("delayed query unexpectedly completed")
      } catch {
        #expect(error is AppViewFeedQueryDeadline.Failure || (error as? PSQLError)?.serverInfo?[.sqlState] == "57014")
      }
      #expect(start.duration(to: .now) < .seconds(2))
      try await expectHealthy(pool)
    }
  }

  @Test("waiting for a saturated pool consumes the same deadline without closing another lease")
  func poolWait() async throws {
    try await withPool { pool in
      try await pool.withConnection { held in
        let start = ContinuousClock.now
        do {
          _ = try await AppViewFeedQueryDeadline.$current.withValue(.init(duration: .milliseconds(150))) {
            try await PostgresFeedQueryExecutor.query("SELECT 1", pool: pool, logger: logger)
          }
          Issue.record("saturated pool unexpectedly provided another lease")
        } catch {
          #expect(error is AppViewFeedQueryDeadline.Failure)
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(!held.isClosed)
        _ = try await held.query("SELECT 1", logger: logger)
      }
      try await expectHealthy(pool)
    }
  }

  @Test("an already cancelled task cannot enqueue feed work")
  func cancellation() async throws {
    try await withPool { pool in
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AppViewFeedQueryDeadline.$current.withValue(.init()) {
          try await PostgresFeedQueryExecutor.query("SELECT pg_sleep(5)", pool: pool, logger: logger)
        }
      }
      do { _ = try await task.value; Issue.record("cancelled work succeeded") }
      catch { #expect(error is CancellationError) }
      try await expectHealthy(pool)
    }
  }

  @Test("cancelling an executing query retires its lease and server work stops within its budget")
  func activeCancellation() async throws {
    try await withPool { observer in
      try await withPool { pool in
        let sql = "SELECT pg_sleep(5) /* feed-cancel-\(UUID().uuidString) */"
        let task = Task {
          try await AppViewFeedQueryDeadline.$current.withValue(.init(duration: .milliseconds(400))) {
            try await PostgresFeedQueryExecutor.query(.init(unsafeSQL: sql), pool: pool, logger: logger)
          }
        }
        defer { task.cancel() }
        var observed = false
        let observationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < observationDeadline {
          let rows = try await PostgresFeedQueryExecutor.query(
            "SELECT count(*)::int FROM pg_stat_activity WHERE query = \(sql) AND state = 'active'",
            pool: observer, logger: logger)
          if try #require(rows.first).decode(Int.self) == 1 { observed = true; break }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("cancelled query succeeded") }
        catch { #expect(error is CancellationError || error is PSQLError) }
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
        try await expectHealthy(pool)
        // Closing the socket retires the client immediately. PostgreSQL notices a
        // disconnect at its next interrupt; the local timeout bounds server work too.
        var active = 1
        let serverDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while active > 0 && ContinuousClock.now < serverDeadline {
          let rows = try await PostgresFeedQueryExecutor.query(
            "SELECT count(*)::int FROM pg_stat_activity WHERE query = \(sql) AND state = 'active'",
            pool: observer, logger: logger)
          active = try #require(rows.first).decode(Int.self)
          if active > 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(active == 0)
      }
    }
  }

  @Test("successful query uses remaining time and restores the session setting")
  func successfulRemainingBudget() async throws {
    try await withPool { pool in
      let deadline = AppViewFeedQueryDeadline(duration: .seconds(2), startedAt: .now.advanced(by: .milliseconds(-500)))
      let rows = try await AppViewFeedQueryDeadline.$current.withValue(deadline) {
        try await PostgresFeedQueryExecutor.query("SELECT current_setting('statement_timeout')", pool: pool, logger: logger)
      }
      let timeout = try #require(rows.first).decode(String.self)
      let milliseconds = try #require(Int(timeout.replacingOccurrences(of: "ms", with: "")))
      #expect(milliseconds > 0 && milliseconds <= 1475)
      try await expectHealthy(pool)
    }
  }

  private func expectHealthy(_ pool: PostgresClient) async throws {
    let rows = try await PostgresFeedQueryExecutor.query("SHOW statement_timeout", pool: pool, logger: logger)
    #expect(try #require(rows.first).decode(String.self) == "0")
  }

  private func withPool(_ body: @Sendable (PostgresClient) async throws -> Void) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"])
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 1
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let run = Task { await pool.run() }
    await Task.yield()
    do {
      try await expectHealthy(pool)
      try await body(pool)
    } catch {
      run.cancel(); await run.value
      throw error
    }
    run.cancel(); await run.value
  }
}
