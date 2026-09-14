import Foundation

/// Minimal internal store projection for age counts and snapshot-based read mutations.
/// Publication identity preserves the first matching scope; display payload is never hydrated.
public struct UnreadReadMutationEntry: Sendable, Equatable {
  public let entryId: String
  public let publishedAt: Date
  public let feedPositionAt: Date
  public let publicationId: String

  public init(entryId: String, publishedAt: Date, feedPositionAt: Date, publicationId: String) {
    self.entryId = entryId
    self.publishedAt = publishedAt
    self.feedPositionAt = feedPositionAt
    self.publicationId = publicationId
  }
}
