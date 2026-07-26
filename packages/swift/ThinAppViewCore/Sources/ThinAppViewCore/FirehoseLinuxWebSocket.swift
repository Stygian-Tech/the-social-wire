#if canImport(WebSocketKit)
import Foundation
import Logging
import NIOCore
import NIOPosix
import WebSocketKit

/// Jetstream consumer for Linux hosts where Foundation `URLSession` WebSockets use libcurl without `wss` support.
enum FirehoseLinuxWebSocket {
  private static let pingInterval = TimeAmount.seconds(15)
  private static let pongTimeout: TimeInterval = 35
  private static let watchdogPollInterval: TimeInterval = 5

  static func consume(
    relayURL: String,
    logger: Logger,
    queueCapacity: Int = 4_096,
    onConnected: @Sendable @escaping () async -> Void,
    onHeartbeat: @Sendable @escaping () async -> Void = {},
    onQueueObservation: @Sendable @escaping (BoundedQueueObservation) async -> Void = { _ in },
    handleMessage: @Sendable @escaping (String) async throws -> Void
  ) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let socketBox = WebSocketBox()

    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          let resumed = ContinuationGuard()

          WebSocket.connect(to: relayURL, on: group) { ws in
            socketBox.set(ws)
            Task { await onConnected() }
            let pongDeadline = WebSocketPongDeadline(connectedAt: Date())
            ws.pingInterval = Self.pingInterval
            ws.onPong { _, _ in
              pongDeadline.recordPong(at: Date())
              Task { await onHeartbeat() }
            }
            let watchdog = Task {
              do {
                while !Task.isCancelled {
                  try await Task.sleep(for: .seconds(Self.watchdogPollInterval))
                  let expired = WebSocketPongWatchdog.expireIfNeeded(
                    deadline: pongDeadline,
                    at: Date(),
                    timeout: Self.pongTimeout
                  ) {
                    resumed.resumeOnce(
                      continuation,
                      with: .failure(WebSocketHeartbeatError.pongTimeout)
                    )
                    socketBox.close()
                  }
                  if expired { return }
                }
              } catch {
                return
              }
            }
            socketBox.setWatchdog(watchdog)
            let pump = BoundedSequentialMessagePump(
              capacity: queueCapacity,
              handleMessage: handleMessage,
              onFailure: { error in
                resumed.resumeOnce(continuation, with: .failure(error))
                socketBox.close()
              },
              onObservation: { observation in
                Task { await onQueueObservation(observation) }
              }
            )
            logger.info("Firehose connected", metadata: ["url": .string(relayURL)])

            ws.onText { _, text in
              guard pump.enqueue(text) else {
                logger.warning("Firehose message pump saturated; reconnecting")
                resumed.resumeOnce(continuation, with: .failure(FirehoseQueueOverflowError()))
                socketBox.close()
                return
              }
            }

            ws.onClose.whenComplete { result in
              socketBox.stopWatchdog()
              resumed.resumeOnce(continuation, with: result.map { _ in () })
            }
          }.whenFailure { error in
            resumed.resumeOnce(continuation, with: .failure(error))
          }
        }
      } onCancel: {
        socketBox.close()
      }
    } catch {
      try await group.shutdownGracefully()
      throw error
    }
    try await group.shutdownGracefully()
  }
}

private final class WebSocketBox: @unchecked Sendable {
  private let lock = NSLock()
  private var webSocket: WebSocket?
  private var watchdog: Task<Void, Never>?

  func set(_ ws: WebSocket) {
    lock.lock()
    defer { lock.unlock() }
    webSocket = ws
  }

  func setWatchdog(_ watchdog: Task<Void, Never>) {
    lock.lock()
    let previous = self.watchdog
    self.watchdog = watchdog
    lock.unlock()
    previous?.cancel()
  }

  func stopWatchdog() {
    lock.lock()
    let watchdog = self.watchdog
    self.watchdog = nil
    lock.unlock()
    watchdog?.cancel()
  }

  func close() {
    lock.lock()
    let ws = webSocket
    let watchdog = self.watchdog
    self.watchdog = nil
    lock.unlock()
    watchdog?.cancel()
    _ = ws?.close()
  }
}

private final class ContinuationGuard: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false

  func resumeOnce(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else { return }
    didResume = true
    continuation.resume(with: result)
  }
}
#endif
