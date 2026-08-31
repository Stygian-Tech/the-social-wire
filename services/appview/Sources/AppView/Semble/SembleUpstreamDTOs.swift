import Foundation

struct SembleUpstreamPagination: Decodable, Sendable {
  let currentPage: Int
  let hasMore: Bool
}

struct SembleUpstreamUser: Decodable, Sendable {
  let id: String
  let name: String?
  let handle: String?
  let avatarUrl: String?
}

struct SembleUpstreamCollection: Decodable, Sendable {
  let id: String
  let uri: String?
  let name: String
  let description: String?
  let accessType: String?
  let cardCount: Int
  let createdAt: String?
  let updatedAt: String?
  let author: SembleUpstreamUser
}

struct SembleUpstreamCollectionsPage: Decodable, Sendable {
  let collections: [SembleUpstreamCollection]
  let pagination: SembleUpstreamPagination
}

struct SembleUpstreamURLMetadata: Decodable, Sendable {
  let url: String?
  let title: String?
  let description: String?
  let publishedDate: String?
  let siteName: String?
  let imageUrl: String?
}

struct SembleUpstreamNote: Decodable, Sendable {
  let id: String
  let text: String
}

struct SembleUpstreamCard: Decodable, Sendable {
  let id: String
  let type: String
  let url: String?
  let uri: String?
  let cid: String?
  let cardContent: SembleUpstreamURLMetadata?
  let createdAt: String?
  let author: SembleUpstreamUser
  let note: SembleUpstreamNote?
}

struct SembleUpstreamCollectionPage: Decodable, Sendable {
  let id: String
  let uri: String?
  let name: String
  let description: String?
  let accessType: String?
  let cardCount: Int
  let createdAt: String?
  let updatedAt: String?
  let author: SembleUpstreamUser
  let urlCards: [SembleUpstreamCard]
  let pagination: SembleUpstreamPagination
}

struct SembleUpstreamURLView: Decodable, Sendable {
  let url: String
}

struct SembleUpstreamConnectionValue: Decodable, Sendable {
  let id: String
  let uri: String?
  let type: String?
  let note: String?
  let createdAt: String?
  let updatedAt: String?
  let curator: SembleUpstreamUser
}

struct SembleUpstreamConnection: Decodable, Sendable {
  let connection: SembleUpstreamConnectionValue
  let source: SembleUpstreamURLView
  let target: SembleUpstreamURLView
}

struct SembleUpstreamConnectionsPage: Decodable, Sendable {
  let connections: [SembleUpstreamConnection]
  let pagination: SembleUpstreamPagination
}

struct SemblePDSStrongRef: Decodable, Sendable {
  let uri: String
  let cid: String?
}

struct SemblePDSCollectionLinkValue: Decodable, Sendable {
  let collection: SemblePDSStrongRef
  let card: SemblePDSStrongRef
  let originalCard: SemblePDSStrongRef?
  let addedBy: String
  let addedAt: String?
}

struct SemblePDSNoteContent: Decodable, Sendable {
  let text: String
}

struct SemblePDSCardValue: Decodable, Sendable {
  let type: String
  let content: SemblePDSNoteContent?
  let parentCard: SemblePDSStrongRef?
  let createdAt: String?
}

struct SemblePDSConnectionValue: Decodable, Sendable {
  let source: String
  let target: String
  let connectionType: String?
  let note: String?
  let createdAt: String?
  let updatedAt: String?
}
