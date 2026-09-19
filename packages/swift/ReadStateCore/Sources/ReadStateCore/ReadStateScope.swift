import Foundation

/// Frozen publication identity. Empty site keys mean every item by this author.
public struct ReadStateScope: Codable, Sendable, Equatable {
  public let publicationId: String
  public let authorDid: String
  public let publicationSiteKeys: [String]

  public init(publicationId: String, authorDid: String, publicationSiteKeys: [String]) {
    self.publicationId = publicationId
    self.authorDid = authorDid
    self.publicationSiteKeys = publicationSiteKeys
  }
}
