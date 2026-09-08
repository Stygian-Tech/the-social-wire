import Foundation

public struct ReadStateSubject: Sendable, Equatable {
  public let uri: String
  public let authorDid: String
  public let publicationSite: String?
  public let createdAt: Date

  public init(uri: String, authorDid: String, publicationSite: String?, createdAt: Date) {
    self.uri = uri
    self.authorDid = authorDid
    self.publicationSite = publicationSite
    self.createdAt = createdAt
  }
}
