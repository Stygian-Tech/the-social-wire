#if !canImport(WebSocketKit)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

enum FirehoseSubscriberURLSessionTransport {
  static func consume(
    relayURL: String,
    logger: Logger,
    isCancelled: @Sendable @escaping () -> Bool,
    onConnected: @Sendable @escaping () async -> Void,
    onHeartbeat: @Sendable @escaping () async -> Void = {},
    onQueueObservation: @Sendable @escaping (BoundedQueueObservation) async -> Void = { _ in },
    handleMessage: @Sendable @escaping (String) async throws -> Void
  ) async throws {
    guard let url = URL(string: relayURL) else {
      throw FirehoseSubscriberError.invalidURL
    }

    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    try await WebSocketPingDeadline.wait { completion in
      task.sendPing(pongReceiveHandler: completion)
    }
    await onConnected()
    defer {
      task.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
    }

    logger.info("Firehose connected", metadata: ["url": .string(relayURL)])
    await onQueueObservation(BoundedQueueObservation(depth: 0, capacity: 1, dropped: 0))

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        while !isCancelled() {
          let message = try await task.receive()
          await onQueueObservation(BoundedQueueObservation(depth: 1, capacity: 1, dropped: 0))
          switch message {
          case .string(let text):
            try await handleMessage(text)
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              try await handleMessage(text)
            }
          @unknown default:
            continue
          }
          await onQueueObservation(BoundedQueueObservation(depth: 0, capacity: 1, dropped: 0))
        }
      }
      group.addTask {
        while !isCancelled() {
          try await Task.sleep(for: .seconds(15))
          try await WebSocketPingDeadline.wait { completion in
            task.sendPing(pongReceiveHandler: completion)
          }
          await onHeartbeat()
        }
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }
}
#endif
