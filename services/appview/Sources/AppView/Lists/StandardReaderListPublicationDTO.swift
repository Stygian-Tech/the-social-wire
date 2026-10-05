import Foundation

struct StandardReaderListPublicationDTO: Codable, Sendable, Equatable {
  let publicationId: String
  let title: String
  let authorDid: String
  let authorHandle: String?
  let iconUrl: String?
  let avatarUrl: String?
}

struct StandardReaderListPublicationRead: Sendable {
  let details: StandardReaderListPublicationDTO?
  let siteURL: String?
}
