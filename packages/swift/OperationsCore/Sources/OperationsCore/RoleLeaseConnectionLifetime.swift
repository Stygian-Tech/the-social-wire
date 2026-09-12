import Foundation
import Logging
import PostgresNIO

/// Never retains a connection beyond its pool lease. Cancellation racing acquisition
/// either closes the acquired connection or prevents it from being used.
final class RoleLeaseConnectionLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private let deadline: RoleLeaseOperationDeadline
  private var connection: PostgresConnection?
  private var cancelled = false

  init(deadline: RoleLeaseOperationDeadline) { self.deadline = deadline }

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
      return try deadline.submit {
        connection.query(query, logger: logger).flatMapThrowing { $0.rows }
      }
    }
    let rows = try await future.get()
    try deadline.check()
    return rows
  }

  func finish() async {
    let closing = lock.withLock {
      let closing = cancelled ? connection : nil
      connection = nil
      return closing
    }
    // A closing connection must not be offered to a new borrower while its close
    // is still queued on the NIO event loop.
    if let closing { try? await closing.close() }
  }

  func cancel() {
    // Closing under this lock prevents returning the connection to a new borrower
    // between selecting the cancellation target and closing it.
    lock.withLock {
      cancelled = true
      connection?.close().whenComplete { _ in }
    }
  }
}
