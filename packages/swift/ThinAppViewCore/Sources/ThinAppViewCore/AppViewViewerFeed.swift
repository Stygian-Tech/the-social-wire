import Foundation

public struct AppViewViewerFeed: Codable, Sendable, Equatable {
  public let viewerDid: String
  public let kind: AppViewFeedKind
  public let feedId: String
  public let updatedAt: Date

  public init(viewerDid: String, kind: AppViewFeedKind, feedId: String, updatedAt: Date) {
    self.viewerDid = viewerDid
    self.kind = kind
    self.feedId = feedId
    self.updatedAt = updatedAt
  }
}
