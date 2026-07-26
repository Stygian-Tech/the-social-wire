import Foundation
import Testing

@testable import ThinAppViewCore

@Suite("WebSocket transport heartbeat")
struct WebSocketHeartbeatSupportTests {
  @Test("pong deadline expires a quiet half-open transport")
  func pongDeadlineExpires() {
    let connectedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let deadline = WebSocketPongDeadline(connectedAt: connectedAt)
    #expect(!deadline.isExpired(at: connectedAt.addingTimeInterval(30), timeout: 30))
    #expect(deadline.isExpired(at: connectedAt.addingTimeInterval(31), timeout: 30))
  }

  @Test("fresh pong extends the transport deadline")
  func pongExtendsDeadline() {
    let connectedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let deadline = WebSocketPongDeadline(connectedAt: connectedAt)
    deadline.recordPong(at: connectedAt.addingTimeInterval(20))
    #expect(!deadline.isExpired(at: connectedAt.addingTimeInterval(49), timeout: 30))
    #expect(deadline.isExpired(at: connectedAt.addingTimeInterval(51), timeout: 30))
  }

  @Test("expired pong watchdog invokes the transport close path")
  func pongExpiryClosesTransport() {
    let connectedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let deadline = WebSocketPongDeadline(connectedAt: connectedAt)
    let closeProbe = LockedCloseProbe()

    let beforeDeadline = WebSocketPongWatchdog.expireIfNeeded(
      deadline: deadline,
      at: connectedAt.addingTimeInterval(30),
      timeout: 30
    ) {
      closeProbe.recordClose()
    }
    #expect(!beforeDeadline)
    #expect(closeProbe.count == 0)

    let expired = WebSocketPongWatchdog.expireIfNeeded(
      deadline: deadline,
      at: connectedAt.addingTimeInterval(31),
      timeout: 30
    ) {
      closeProbe.recordClose()
    }
    #expect(expired)
    #expect(closeProbe.count == 1)
  }

  @Test("ping callback timeout fails closed")
  func pingCallbackTimeout() async {
    await #expect(throws: WebSocketHeartbeatError.pongTimeout) {
      try await WebSocketPingDeadline.wait(timeout: 0.01) { _ in }
    }
  }
}

private final class LockedCloseProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func recordClose() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}
