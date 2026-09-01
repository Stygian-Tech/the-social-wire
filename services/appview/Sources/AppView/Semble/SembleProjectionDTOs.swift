import Foundation
import Hummingbird

struct SembleCollectionDTO: Codable, Equatable, Sendable {
  let uri: String
  let name: String
  let description: String?
  let accessType: String?
  let cardCount: Int
  let createdAt: String?
  let updatedAt: String?
}

struct SembleCollectionsResponseDTO: Codable, Equatable, Sendable, ResponseEncodable {
  let collections: [SembleCollectionDTO]
  let cursor: String?
}

enum SembleCardTypeDTO: String, Codable, Equatable, Sendable {
  case url = "URL"
  case note = "NOTE"
}

struct SembleMembershipDTO: Codable, Equatable, Sendable {
  let linkUri: String
  let linkCid: String?
  let authorDid: String
  let addedBy: String
  let addedAt: String?
  let viewerOwned: Bool
}

struct SembleContributorDTO: Codable, Equatable, Sendable {
  let did: String
  let handle: String?
  let displayName: String?
  let avatar: String?
}

struct SembleNoteDTO: Codable, Equatable, Sendable {
  let uri: String?
  let text: String
  let authorDid: String
  let editable: Bool
}

struct SembleCollectionItemDTO: Codable, Equatable, Sendable {
  let id: String
  let cardUri: String
  let cardCid: String?
  let cardType: SembleCardTypeDTO
  let url: String?
  let title: String?
  let description: String?
  let image: String?
  let siteName: String?
  let publishedAt: String?
  let createdAt: String?
  let membership: SembleMembershipDTO?
  let unlinkAvailable: Bool
  let contributor: SembleContributorDTO
  let note: SembleNoteDTO?
}

struct SembleCollectionPageResponseDTO: Codable, Equatable, Sendable, ResponseEncodable {
  let collection: SembleCollectionDTO
  let items: [SembleCollectionItemDTO]
  let cursor: String?
  let membershipComplete: Bool
  let recordLinksComplete: Bool
}

struct SembleConnectionDTO: Codable, Equatable, Sendable {
  let uri: String?
  let source: String
  let target: String
  let connectionType: String?
  let note: String?
  let createdAt: String?
  let updatedAt: String?
  let authorDid: String
  let editable: Bool
}

struct SembleConnectionsResponseDTO: Codable, Equatable, Sendable, ResponseEncodable {
  let connections: [SembleConnectionDTO]
  let cursor: String?
  let recordLinksComplete: Bool
}
