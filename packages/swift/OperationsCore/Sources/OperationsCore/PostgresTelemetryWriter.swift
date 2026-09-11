import Logging
import PostgresNIO

/// Keep transaction progress, including COMMIT, independent of the shared store actor.
/// Queries arrive fully encoded and retain the events -> spans -> metrics lock order.
enum PostgresTelemetryWriter {
  nonisolated static func write(
    _ queries: [PostgresQuery],
    pool: PostgresClient,
    logger: Logger,
    statementTimeoutMilliseconds: Int
  ) async throws {
    guard !queries.isEmpty else { return }
    try await pool.withTransaction(logger: logger, isolation: nil) { connection in
      let budget = PostgresTelemetryWriteBudget(
        statementTimeoutMilliseconds: statementTimeoutMilliseconds)
      try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: logger)
      // Sampled metrics/events/traces are already best-effort and bounded in memory.
      // Do not hold shared rollup locks while waiting for a WAL flush. A database
      // crash may lose recently acknowledged telemetry; audit/control/ingestion
      // transactions never use this helper and retain synchronous durability.
      try await connection.query("SET LOCAL synchronous_commit = 'off'", logger: logger)
      for query in queries {
        try Task.checkCancellation()
        let timeout = try budget.remainingStatementMilliseconds()
        try await connection.query(
          "SELECT set_config('statement_timeout', \(String(timeout)), true)", logger: logger)
        try await connection.query(query, logger: logger)
      }
      try Task.checkCancellation()
      _ = try budget.remainingStatementMilliseconds()
    }
  }
}
