import Foundation

struct WireInboxEvent: Sendable {
  let environment: String
  let sourceGeneration: String
  let sequence: Int64
  let sourceHost: String
  let cursorKind: String
  let eventKind: String
  let repoDID: String
  let collection: String?
  let operation: String?
  let recordKey: String?
  let payloadJSON: String
  let eventTime: Date
  let leaseToken: String
  let attemptCount: Int

  var sourceURI: String? {
    guard let collection, let recordKey else { return nil }
    return "at://\(repoDID)/\(collection)/\(recordKey)"
  }
  var repository: WireInboxRepository {
    WireInboxRepository(
      environment: environment, sourceGeneration: sourceGeneration, repoDID: repoDID)
  }

  var isPassiveDelete: Bool {
    operation == "delete"
      && (collection == "app.bsky.feed.like" || collection == "app.bsky.feed.repost")
  }
}
