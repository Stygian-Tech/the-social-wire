import Foundation
import Logging
import NIOCore
import PostgresNIO

/// Cancellation and query submission share a lock so a retired connection cannot
/// receive another statement or be returned to the pool while closure is pending.
final class AppViewFeedConnectionLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private let deadline: AppViewFeedQueryDeadline
  private var connection: PostgresConnection?
  private var cancelled = false

  init(deadline: AppViewFeedQueryDeadline) { self.deadline = deadline }

  func install(_ connection: PostgresConnection) async throws {
    do {
      try lock.withLock {
        guard !cancelled else { throw CancellationError() }
        try deadline.check()
        self.connection = connection
      }
    } catch {
      try? await connection.close()
      throw error
    }
  }

  func query(_ query: PostgresQuery, connection: PostgresConnection, logger: Logger) async throws -> [PostgresRow] {
    try deadline.check()
    let rows = try await submitQuery(query, connection: connection, logger: logger).get()
    try deadline.check()
    return rows
  }

  /// Channel closure and the guarded write must run in the same event-loop turn.
  /// A lock alone cannot prevent a remote close between isClosed and enqueueing
  /// the driver's write, which can leave its result promise unresolved.
  func submitQuery(
    _ query: PostgresQuery, connection: PostgresConnection, logger: Logger
  ) -> EventLoopFuture<[PostgresRow]> {
    connection.eventLoop.submit {
      try self.lock.withLock {
        guard !self.cancelled else { throw CancellationError() }
        guard !connection.isClosed else { throw PostgresError.connectionClosed }
        try self.deadline.check()
        return connection.query(query, logger: logger).flatMapThrowing { $0.rows }
      }
    }.flatMap { $0 }
  }

  func cancel() {
    lock.withLock {
      cancelled = true
      connection?.close().whenComplete { _ in }
    }
  }

  func finish() async {
    let closing = lock.withLock {
      let closing = cancelled ? connection : nil
      connection = nil
      return closing
    }
    if let closing { try? await closing.close() }
  }
}
