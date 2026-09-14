import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite(
  "PostgreSQL telemetry commit policy",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."
  )
)
struct PostgresTelemetryCommitPolicyTests {
  @Test("asynchronous telemetry commit remains local through both commit and rollback")
  func synchronousDurabilityDoesNotLeak() async throws {
    let rawURL = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: rawURL))
    let logger = Logger(label: "operations-telemetry-commit.tests")
    var config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    // One connection guarantees that the next borrower inspects the same session.
    config.options.maximumConnections = 1
    config.options.additionalStartupParameters = [("synchronous_commit", "on")]
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let verifyLocalPolicy: PostgresQuery = """
      DO $$ BEGIN
        IF current_setting('synchronous_commit') <> 'off' THEN
          RAISE EXCEPTION 'Telemetry must use transaction-local asynchronous commit';
        END IF;
        IF current_setting('lock_timeout') <> '500ms' THEN
          RAISE EXCEPTION 'Telemetry lock timeout changed';
        END IF;
        IF current_setting('statement_timeout') <> '2s' THEN
          RAISE EXCEPTION 'Telemetry statement timeout changed';
        END IF;
      END $$
      """
    try await PostgresTelemetryWriter.write(
      [verifyLocalPolicy], pool: pool, logger: logger, statementTimeoutMilliseconds: 2_000)
    try await expectSynchronousSession(pool: pool, logger: logger)
    do {
      try await PostgresTelemetryWriter.write(
        [verifyLocalPolicy, "SELECT 1 / 0"], pool: pool, logger: logger,
        statementTimeoutMilliseconds: 2_000)
      Issue.record("Expected the second statement to abort the transaction")
    } catch let error as PostgresTransactionError {
      #expect(error.closureError != nil && error.rollbackError == nil)
    }
    try await expectSynchronousSession(pool: pool, logger: logger)
  }

  private func expectSynchronousSession(pool: PostgresClient, logger: Logger) async throws {
    let rows = try await pool.query("SHOW synchronous_commit", logger: logger)
    var found = false
    for try await row in rows {
      #expect(try row.decode(String.self) == "on")
      found = true
    }
    #expect(found)
  }
}
