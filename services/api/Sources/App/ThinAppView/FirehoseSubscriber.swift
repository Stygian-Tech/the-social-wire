import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

/// Consumes Jetstream / relay WebSocket commits and forwards them to the indexer.
actor FirehoseSubscriber {
  private let relayURL: String
  private let indexer: ThinAppViewIndexer
  private let logger: Logger

  init(
    relayURL: String,
    indexer: ThinAppViewIndexer,
    logger: Logger
  ) {
    self.relayURL = relayURL
    self.indexer = indexer
    self.logger = logger
  }

  func runForever() async {
    while !Task.isCancelled {
      do {
        try await consumeOnce()
      } catch {
        logger.warning("Firehose disconnected; reconnecting", metadata: ["error": .string("\(error)")])
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  private func consumeOnce() async throws {
    guard let url = URL(string: relayURL) else {
      throw FirehoseSubscriberError.invalidURL
    }

    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    defer {
      task.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
    }

    logger.info("Firehose connected", metadata: ["url": .string(relayURL)])

    while !Task.isCancelled {
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

  private func handleMessage(_ text: String) async throws {
    guard
      let data = text.data(using: .utf8),
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    guard (json["kind"] as? String) == "commit" else { return }
    guard
      let did = json["did"] as? String,
      let commit = json["commit"] as? [String: Any],
      let collection = commit["collection"] as? String,
      let rkey = commit["rkey"] as? String,
      let operation = commit["operation"] as? String
    else { return }

    let cid = (commit["cid"] as? String) ?? ""
    let recordObject = commit["record"] ?? [:]
    let recordJSON = (try? JSONSerialization.data(withJSONObject: recordObject)) ?? Data("{}".utf8)

    try await indexer.handleCommit(
      repoDid: did,
      collection: collection,
      rkey: rkey,
      cid: cid,
      recordJSON: recordJSON,
      operation: operation
    )
  }
}

enum FirehoseSubscriberError: Error, CustomStringConvertible {
  case invalidURL

  var description: String {
    switch self {
    case .invalidURL: "Invalid firehose WebSocket URL"
    }
  }
}
