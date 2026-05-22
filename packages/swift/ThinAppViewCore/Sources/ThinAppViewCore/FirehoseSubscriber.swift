import Foundation
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
    #if canImport(WebSocketKit)
    try await FirehoseLinuxWebSocket.consume(relayURL: relayURL, logger: logger) { text in
      try await self.handleMessage(text)
    }
    #else
    try await FirehoseSubscriberURLSessionTransport.consume(
      relayURL: relayURL,
      logger: logger,
      isCancelled: { Task.isCancelled }
    ) { text in
      try await self.handleMessage(text)
    }
    #endif
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
