#if canImport(WebSocketKit)
import Foundation
import Logging
import NIOCore
import NIOPosix
import WebSocketKit

/// Jetstream consumer for Linux hosts where Foundation `URLSession` WebSockets use libcurl without `wss` support.
enum FirehoseLinuxWebSocket {
  static func consume(
    relayURL: String,
    logger: Logger,
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
            logger.info("Firehose connected", metadata: ["url": .string(relayURL)])

            ws.onText { _, text in
              Task {
                do {
                  try await handleMessage(text)
                } catch {
                  logger.warning(
                    "Firehose message handling failed",
                    metadata: ["error": .string("\(error)")]
                  )
                }
              }
            }

            ws.onClose.whenComplete { result in
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

  func set(_ ws: WebSocket) {
    lock.lock()
    defer { lock.unlock() }
    webSocket = ws
  }

  func close() {
    lock.lock()
    let ws = webSocket
    lock.unlock()
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
