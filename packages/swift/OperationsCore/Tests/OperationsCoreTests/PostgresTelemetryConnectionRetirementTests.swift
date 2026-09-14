import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite(
  "PostgreSQL telemetry connection retirement",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."
  )
)
struct PostgresTelemetryConnectionRetirementTests {
  @Test("an aborted session is retired before another borrower can inherit it")
  func abortedSessionIsNotRecycled() async throws {
    try await withPool { pool, logger in
      let originalPID = try await session(pool: pool, logger: logger).pid
      // Model a borrower whose transaction cleanup failed before returning its lease.
      try await pool.withConnection { connection in
        try await connection.query("BEGIN", logger: logger)
        do {
          try await connection.query(
            "DO $$ BEGIN RAISE EXCEPTION 'test transaction failure'; END $$", logger: logger)
          Issue.record("Expected the fixture transaction to become aborted")
        } catch let error as PSQLError {
          #expect(error.serverInfo?[.sqlState] == "P0001")
        }
      }
      do {
        try await PostgresTelemetryWriter.write(
          ["SELECT 1"], pool: pool, logger: logger, statementTimeoutMilliseconds: 2_000)
        Issue.record("Expected BEGIN to reject the already aborted transaction")
      } catch let error as PostgresTransactionError {
        let begin = try #require(error.beginError as? PSQLError)
        #expect(begin.serverInfo?[.sqlState] == "25P02")
        #expect(error.closureError == nil && error.commitError == nil)
        #expect(!PostgresTelemetryRetryPolicy.canRetry(error))
      }
      let replacement = try await session(pool: pool, logger: logger)
      #expect(replacement.pid != originalPID)
      #expect(replacement.synchronousCommit == "on")
      try await PostgresTelemetryWriter.write(
        ["SELECT 1"], pool: pool, logger: logger, statementTimeoutMilliseconds: 2_000)
    }
  }

  @Test("a failed commit retires its connection and preserves the original error")
  func failedCommitRetiresSession() async throws {
    try await withPool { pool, logger in
      let originalPID = try await session(pool: pool, logger: logger).pid
      try await pool.query(
        "CREATE TEMP TABLE telemetry_commit_fixture (value integer UNIQUE DEFERRABLE INITIALLY DEFERRED)",
        logger: logger)
      do {
        try await PostgresTelemetryWriter.write(
          ["INSERT INTO telemetry_commit_fixture VALUES (1), (1)"],
          pool: pool, logger: logger, statementTimeoutMilliseconds: 2_000)
        Issue.record("Expected the deferred constraint to fail at COMMIT")
      } catch let error as PostgresTransactionError {
        let commit = try #require(error.commitError as? PSQLError)
        #expect(commit.serverInfo?[.sqlState] == "23505")
        #expect(error.beginError == nil && error.closureError == nil)
        #expect(!PostgresTelemetryRetryPolicy.canRetry(error))
      }
      let replacement = try await session(pool: pool, logger: logger)
      #expect(replacement.pid != originalPID)
      #expect(replacement.synchronousCommit == "on")
    }
  }

  @Test("a confirmed rollback preserves a healthy pooled session")
  func confirmedRollbackKeepsSession() async throws {
    try await withPool { pool, logger in
      let originalPID = try await session(pool: pool, logger: logger).pid
      do {
        try await PostgresTelemetryWriter.write(
          ["DO $$ BEGIN RAISE EXCEPTION 'test transaction failure'; END $$"],
          pool: pool, logger: logger, statementTimeoutMilliseconds: 2_000)
        Issue.record("Expected the statement to abort the transaction")
      } catch let error as PostgresTransactionError {
        #expect(error.closureError != nil && error.rollbackError == nil)
        #expect(error.beginError == nil && error.commitError == nil)
      }
      let retained = try await session(pool: pool, logger: logger)
      #expect(retained.pid == originalPID)
      #expect(retained.synchronousCommit == "on")
    }
  }

  private func session(pool: PostgresClient, logger: Logger) async throws
    -> (pid: Int32, synchronousCommit: String)
  {
    let rows = try await pool.query(
      "SELECT pg_backend_pid(), current_setting('synchronous_commit')", logger: logger)
    var value: (Int32, String)?
    for try await row in rows { value = try row.decode((Int32, String).self) }
    return try #require(value)
  }

  private func withPool(
    _ body: (PostgresClient, Logger) async throws -> Void
  ) async throws {
    let rawURL = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: rawURL))
    let logger = Logger(label: "operations-telemetry-connection.tests")
    var config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 1
    config.options.additionalStartupParameters = [("synchronous_commit", "on")]
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    try await body(pool, logger)
  }
}
