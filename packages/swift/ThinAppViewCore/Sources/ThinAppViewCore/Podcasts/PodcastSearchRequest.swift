import Foundation

public struct PodcastSearchRequest: Codable, Sendable {
  public var query: String
  public var scope: String?
  public var kind: String?
  public var showId: String?
  public var limit: Int?
  public var cursor: String?

  public init(query: String, scope: String? = nil, kind: String? = nil, showId: String? = nil, limit: Int? = nil, cursor: String? = nil) {
    self.query = query
    self.scope = scope
    self.kind = kind
    self.showId = showId
    self.limit = limit
    self.cursor = cursor
  }

  public func validate() throws {
    let count = query.trimmingCharacters(in: .whitespacesAndNewlines).count
    guard (2...200).contains(count), scope == nil || scope == "library",
      ["all", "shows", "episodes"].contains(kind ?? "all"),
      (1...100).contains(limit ?? 20), (showId?.count ?? 0) <= 2048,
      (cursor?.count ?? 0) <= 4096
    else { throw PodcastStoreError.invalidRequest }
  }
}
