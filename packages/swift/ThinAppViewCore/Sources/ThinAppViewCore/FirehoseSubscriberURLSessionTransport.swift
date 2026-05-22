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
    handleMessage: @Sendable @escaping (String) async throws -> Void
  ) async throws {
    guard let url = URL(string: relayURL) else {
      throw FirehoseSubscriberError.invalidURL
    }

    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    defer {
      task.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
    }

    logger.info("Firehose connected", metadata: ["url": .string(relayURL)])

    while !isCancelled() {
      let message = try await task.receive()
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
    }
  }
}
#endif
