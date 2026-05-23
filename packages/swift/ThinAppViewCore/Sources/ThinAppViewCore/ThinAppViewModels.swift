import Foundation

/// Level-1 render payload stored in `content_items.render_json`.
public struct ContentRenderFields: Codable, Sendable, Equatable {
  public let title: String
  public let publishedAt: String
  public var summary: String?
  public var thumbnailUrl: String?

  public init(
    title: String,
    publishedAt: String,
    summary: String? = nil,
    thumbnailUrl: String? = nil
  ) {
    self.title = title
    self.publishedAt = publishedAt
    self.summary = summary
    self.thumbnailUrl = thumbnailUrl
  }
}

public struct IndexedContentItem: Sendable {
  public let uri: String
  public let cid: String
  public let authorDid: String
  public let collection: String
  public let createdAt: Date
  public let indexedAt: Date
  public let publicationSite: String?
  public let render: ContentRenderFields
  public let expiresAt: Date

  public init(
    uri: String,
    cid: String,
    authorDid: String,
    collection: String,
    createdAt: Date,
    indexedAt: Date,
    publicationSite: String?,
    render: ContentRenderFields,
    expiresAt: Date
  ) {
    self.uri = uri
    self.cid = cid
    self.authorDid = authorDid
    self.collection = collection
    self.createdAt = createdAt
    self.indexedAt = indexedAt
    self.publicationSite = publicationSite
    self.render = render
    self.expiresAt = expiresAt
  }
}

public struct ReadMarkRow: Sendable {
  public let viewerDid: String
  public let subjectUri: String
  public let createdAt: Date
}

public enum EntryListFilter: String, Sendable {
  case all
  case unread
  case read
}

public struct AppViewEntryListItem: Codable, Sendable {
  public let entryId: String
  public let title: String
  public let summary: String?
  public let publishedAt: Date
  public let thumbnailUrl: String?
  public let thumbnailFallbackUrl: String?

  public init(
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

public struct AppViewEntryListResponse: Codable, Sendable {
  public let entries: [AppViewEntryListItem]
  public let cursor: String?

  public init(entries: [AppViewEntryListItem], cursor: String?) {
    self.entries = entries
    self.cursor = cursor
  }
}

public struct AppViewEnrollRequest: Codable, Sendable {
  public let authorDids: [String]
}

public struct AppViewReadMarkRequest: Codable, Sendable {
  public let subjectUri: String
  public let readAt: Date?

  public init(subjectUri: String, readAt: Date?) {
    self.subjectUri = subjectUri
    self.readAt = readAt
  }

  private enum CodingKeys: String, CodingKey {
    case subjectUri
    case readAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    subjectUri = try container.decode(String.self, forKey: .subjectUri)
    if let raw = try container.decodeIfPresent(String.self, forKey: .readAt) {
      readAt = ThinAppViewQuerySupport.parseISO8601Date(raw)
    } else {
      readAt = nil
    }
  }
}

public struct AppViewReadMarkDeleteRequest: Codable, Sendable {
  public let subjectUri: String
}
