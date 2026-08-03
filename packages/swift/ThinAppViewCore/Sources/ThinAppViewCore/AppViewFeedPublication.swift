import Foundation

public struct AppViewFeedPublication: Codable, Sendable, Equatable {
  public let viewerDid: String
  public let kind: AppViewFeedKind
  public let feedId: String
  public let publicationId: String

  public init(viewerDid: String, kind: AppViewFeedKind, feedId: String, publicationId: String) {
    self.viewerDid = viewerDid
    self.kind = kind
    self.feedId = feedId
    self.publicationId = publicationId
  }
}
