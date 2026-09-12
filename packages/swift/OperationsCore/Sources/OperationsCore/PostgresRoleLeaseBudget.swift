import Foundation
import Logging
import PostgresNIO

enum PostgresRoleLeaseBudget {
  @TaskLocal private static var lifetime: RoleLeaseConnectionLifetime?

  /// Lease control and diagnostic results are small and bounded. Synchronous submission
  /// under the cancellation lock closes the check/enqueue race in the driver.
  static func query(
    _ query: PostgresQuery, connection: PostgresConnection, logger: Logger
  ) async throws -> [PostgresRow] {
    if let lifetime { return try await lifetime.query(query, connection: connection, logger: logger) }
    let result = try await connection.query(query, logger: logger).get()
    return result.rows
  }

  static func withTransaction<Value: Sendable>(
    pool: PostgresClient,
    logger: Logger,
    deadline suppliedDeadline: RoleLeaseOperationDeadline? = nil,
    operation: @escaping @Sendable (PostgresConnection) async throws -> Value
  ) async throws -> Value {
    let start = ContinuousClock.now
    let deadline = suppliedDeadline ?? RoleLeaseOperationDeadline(startedAt: start)
    try deadline.check()
    let connectionLifetime = RoleLeaseConnectionLifetime(deadline: deadline)
    let result = try await withThrowingTaskGroup(of: Value.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        try await withTaskCancellationHandler {
          try await pool.withConnection { connection in
            try await connectionLifetime.install(connection)
            let acquired = ContinuousClock.now
            RoleLeaseAttemptMetrics.current?.record(poolWait: milliseconds(start.duration(to: acquired)))
            defer {
              RoleLeaseAttemptMetrics.current?.record(database: milliseconds(acquired.duration(to: .now)))
            }
            do {
              let result = try await $lifetime.withValue(connectionLifetime) {
                _ = try await query("BEGIN", connection: connection, logger: logger)
                try await PostgresRoleLeaseFence.setTimeouts(connection: connection, logger: logger)
                let result = try await operation(connection)
                try Task.checkCancellation()
                try deadline.check()
                _ = try await query("COMMIT", connection: connection, logger: logger)
                return result
              }
              try deadline.check()
              await connectionLifetime.finish()
              return result
            } catch {
              // Closing rolls back unfinished work. Never enqueue the driver's
              // unconditional ROLLBACK on an already closed transport.
              connectionLifetime.cancel()
              await connectionLifetime.finish()
              throw error
            }
          }
        } onCancel: {
          // A Swift future's cancellation need not cancel executing SQL. Retiring this
          // connection completes pending query futures as well.
          connectionLifetime.cancel()
        }
      }
      group.addTask {
        try await ContinuousClock().sleep(until: deadline.instant)
        throw RoleLeaseFailure.operationTimedOut
      }
      guard let value = try await group.next() else { throw CancellationError() }
      try deadline.check()
      return value
    }
    // Joining cancelled siblings may itself be delayed by executor pressure.
    // A result that resumes after the deadline must not become a successful grant.
    try deadline.check()
    return result
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1_000_000_000_000_000
  }
}
