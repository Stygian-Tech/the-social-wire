import Foundation
import Logging
import PostgresNIO

/// Feed, publication-entry, and authoritative read-state SELECTs share the request
/// budget. Worker and mutation statements keep their existing policies; the timeout
/// is local to this read-only transaction and never changes the global setting.
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
        let poolWait = AppViewFeedRequestTimings.startPoolWait()
        defer { poolWait?.finish() }
        return try await withTaskCancellationHandler {
          try await pool.withConnection { connection in
            poolWait?.finish()
            let transaction = AppViewFeedRequestTimings.startTransaction()
            defer { transaction?.finish() }
            try await lifetime.install(connection)
            do {
              _ = try await lifetime.query("BEGIN READ ONLY", connection: connection, logger: logger)
              let milliseconds = try deadline.statementMilliseconds()
              _ = try await lifetime.query(
                "SELECT set_config('statement_timeout', \(String(milliseconds)), true)",
                connection: connection, logger: logger)
              // Count application SELECT attempts, excluding BEGIN/SET/COMMIT.
              AppViewFeedRequestTimings.recordQuery()
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
