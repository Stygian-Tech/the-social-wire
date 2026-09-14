import Foundation
import Logging
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
    let future = try lock.withLock {
      guard !cancelled, !connection.isClosed else { throw CancellationError() }
      try deadline.check()
      return connection.query(query, logger: logger).flatMapThrowing { $0.rows }
    }
    let rows = try await future.get()
    try deadline.check()
    return rows
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
