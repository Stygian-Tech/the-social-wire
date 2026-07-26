import Foundation

enum WebSocketHeartbeatError: Error, Equatable {
  case pongTimeout
}

/// Thread-safe pong deadline shared by callback-based WebSocketKit transports.
final class WebSocketPongDeadline: @unchecked Sendable {
  private let lock = NSLock()
  private var lastPongAt: Date

  init(connectedAt: Date) {
    lastPongAt = connectedAt
  }

  func recordPong(at: Date) {
    lock.lock()
    lastPongAt = max(lastPongAt, at)
    lock.unlock()
  }

  func isExpired(at: Date, timeout: TimeInterval) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return at.timeIntervalSince(lastPongAt) > max(1, timeout)
  }
}

enum WebSocketPongWatchdog {
  @discardableResult
  static func expireIfNeeded(
    deadline: WebSocketPongDeadline,
    at: Date,
    timeout: TimeInterval,
    onExpired: @Sendable () -> Void
  ) -> Bool {
    guard deadline.isExpired(at: at, timeout: timeout) else { return false }
    onExpired()
    return true
  }
}

enum WebSocketPingDeadline {
  static func wait(
    timeout: TimeInterval = 10,
    send: @Sendable @escaping (@escaping @Sendable (Error?) -> Void) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let guarder = WebSocketPingContinuationGuard(continuation)
      send { error in
        if let error {
          guarder.resume(.failure(error))
        } else {
          guarder.resume(.success(()))
        }
      }
      Task {
        do {
          try await Task.sleep(for: .seconds(max(1, timeout)))
          guarder.resume(.failure(WebSocketHeartbeatError.pongTimeout))
        } catch {
          guarder.resume(.failure(CancellationError()))
        }
      }
    }
  }
}

private final class WebSocketPingContinuationGuard: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?

  init(_ continuation: CheckedContinuation<Void, Error>) {
    self.continuation = continuation
  }

  func resume(_ result: Result<Void, Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}
