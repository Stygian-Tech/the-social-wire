import Foundation

protocol WireTalkedAccountMentionStoring: Sendable {
  func replaceMentions(
    sourceURI: String,
    canonicalKey: String,
    subjectDIDs: [String],
    speakerKeyHash: String,
    occurredAt: Date,
    expiresAt: Date
  ) async throws

  func retract(sourceURI: String, through eventTime: Date) async throws
  func removeActor(did: String, actorKeyHash: String) async throws
  func pruneExpired(asOf: Date) async throws
}
