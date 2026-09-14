import Foundation

/// Internal page with the same created-at/URI keyset ordering as the unread query.
public struct UnreadReadMutationPage: Sendable {
  public let entries: [UnreadReadMutationEntry]
  public let cursor: String?

  public init(entries: [UnreadReadMutationEntry], cursor: String?) {
    self.entries = entries
    self.cursor = cursor
  }

  static func page(matches: [UnreadReadMutationEntry], limit: Int) -> Self {
    let entries = Array(matches.prefix(limit))
    let cursor = matches.count > limit ? entries.last.map {
      ThinAppViewCursor.encode(createdAt: $0.feedPositionAt, uri: $0.entryId)
    } : nil
    return Self(entries: entries, cursor: cursor)
  }
}
