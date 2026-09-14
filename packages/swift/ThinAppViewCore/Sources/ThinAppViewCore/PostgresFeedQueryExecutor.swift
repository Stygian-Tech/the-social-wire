import Foundation
import Logging
import PostgresNIO

/// Only the bounded feed SELECT uses this connection lease. Worker and mutation
/// statements retain their existing policies and never inherit a global timeout.
enum PostgresFeedQueryExecutor {
  static func query(_ query: PostgresQuery, pool: PostgresClient, logger: Logger) async throws -> [PostgresRow] {
    guard let deadline = AppViewFeedQueryDeadline.current else {
      var result: [PostgresRow] = []
      for try await row in try await pool.query(query, logger: logger) { result.append(row) }
      return result
    }
    try deadline.check()
    let lifetime = AppViewFeedConnectionLifetime(deadline: deadline)
    let result = try await withThrowingTaskGroup(of: [PostgresRow].self) { group in
      defer { group.cancelAll() }
      group.addTask {
        try await withTaskCancellationHandler {
          try await pool.withConnection { connection in
            try await lifetime.install(connection)
            do {
              _ = try await lifetime.query("BEGIN READ ONLY", connection: connection, logger: logger)
              let milliseconds = try deadline.statementMilliseconds()
              _ = try await lifetime.query(
                "SELECT set_config('statement_timeout', \(String(milliseconds)), true)",
                connection: connection, logger: logger)
              let rows = try await lifetime.query(query, connection: connection, logger: logger)
              _ = try await lifetime.query("COMMIT", connection: connection, logger: logger)
              await lifetime.finish()
              try deadline.check()
              return rows
            } catch {
              // Closing rolls back unfinished work and completes outstanding query futures.
              // Do not queue an unbounded ROLLBACK on a cancelled/closed transport.
              lifetime.cancel()
              await lifetime.finish()
              throw error
            }
          }
        } onCancel: {
          lifetime.cancel()
        }
      }
      group.addTask {
        try await ContinuousClock().sleep(until: deadline.instant)
        throw AppViewFeedQueryDeadline.Failure.exceeded
      }
      guard let rows = try await group.next() else { throw CancellationError() }
      return rows
    }
    try deadline.check()
    return result
  }
}
