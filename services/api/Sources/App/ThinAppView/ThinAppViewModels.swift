import Foundation

/// Level-1 render payload stored in `content_items.render_json`.
struct ContentRenderFields: Codable, Sendable, Equatable {
  let title: String
  let publishedAt: String
  var summary: String?
  var thumbnailUrl: String?
}

struct IndexedContentItem: Sendable {
  let uri: String
  let cid: String
  let authorDid: String
  let collection: String
  let createdAt: Date
  let indexedAt: Date
  let publicationSite: String?
  let render: ContentRenderFields
  let expiresAt: Date
}

struct ReadMarkRow: Sendable {
  let viewerDid: String
  let subjectUri: String
  let createdAt: Date
}

enum EntryListFilter: String, Sendable {
  case all
  case unread
  case read
}

struct AppViewEntryListItem: Codable, Sendable {
  let entryId: String
  let title: String
  let summary: String?
  let publishedAt: Date
  let thumbnailUrl: String?
  let thumbnailFallbackUrl: String?

  init(
    entryId: String,
    title: String,
    summary: String? = nil,
    publishedAt: Date,
    thumbnailUrl: String? = nil,
    thumbnailFallbackUrl: String? = nil
  ) {
    self.entryId = entryId
    self.title = title
    self.summary = summary
    self.publishedAt = publishedAt
    self.thumbnailUrl = thumbnailUrl
    self.thumbnailFallbackUrl = thumbnailFallbackUrl
  }
}

struct AppViewEntryListResponse: Codable, Sendable {
  let entries: [AppViewEntryListItem]
  let cursor: String?
}

struct AppViewEnrollRequest: Codable, Sendable {
  let authorDids: [String]
}

struct AppViewReadMarkRequest: Codable, Sendable {
  let subjectUri: String
  let readAt: Date?
}

struct AppViewReadMarkDeleteRequest: Codable, Sendable {
  let subjectUri: String
}
