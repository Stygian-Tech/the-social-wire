import Foundation

/// Level-1 render payload stored in `content_items.render_json`.
public struct ContentRenderFields: Codable, Sendable, Equatable {
  public let title: String
  public let publishedAt: String
  public var summary: String?
  public var thumbnailUrl: String?
  public var contentHtml: String?
  /// Canonical article URL for RSS rows (used to collapse guid/link duplicate keys).
  public var articleUrl: String?

  public init(
    title: String,
    publishedAt: String,
    summary: String? = nil,
    thumbnailUrl: String? = nil,
    contentHtml: String? = nil,
    articleUrl: String? = nil
  ) {
    self.title = title
    self.publishedAt = publishedAt
    self.summary = summary
    self.thumbnailUrl = thumbnailUrl
    self.contentHtml = contentHtml
    self.articleUrl = articleUrl
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

public enum AppViewUnreadCounterAccuracy: String, Codable, Sendable, Equatable {
  case estimated
  case exact
}

public struct AppViewPublicationScope: Sendable, Equatable {
  public let viewerDid: String
  public let publicationId: String
  public let authorDid: String
  public let publicationAtUri: String?
  public let publicationScopeAtUris: [String]
  public let publicationSiteUrls: [String]
  public let scopeKeys: [String]
  public let sectionKeys: [String]
  public let updatedAt: Date

  public init(
    viewerDid: String,
    publicationId: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    scopeKeys: [String],
    sectionKeys: [String],
    updatedAt: Date
  ) {
    self.viewerDid = viewerDid
    self.publicationId = publicationId
    self.authorDid = authorDid
    self.publicationAtUri = publicationAtUri
    self.publicationScopeAtUris = publicationScopeAtUris
    self.publicationSiteUrls = publicationSiteUrls
    self.scopeKeys = scopeKeys
    self.sectionKeys = sectionKeys
    self.updatedAt = updatedAt
  }
}

public struct AppViewUnreadCounter: Codable, Sendable, Equatable {
  public let publicationId: String
  public let unreadCount: Int
  public let generation: Int64
  public let accuracy: AppViewUnreadCounterAccuracy
  public let dirty: Bool
  public let countedAt: Date

  public init(
    publicationId: String,
    unreadCount: Int,
    generation: Int64,
    accuracy: AppViewUnreadCounterAccuracy,
    dirty: Bool,
    countedAt: Date
  ) {
    self.publicationId = publicationId
    self.unreadCount = max(0, unreadCount)
    self.generation = generation
    self.accuracy = accuracy
    self.dirty = dirty
    self.countedAt = countedAt
  }
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
  /// Canonical article HTTPS URL when indexed (RSS link, render `articleUrl`, etc.).
  public let originalUrl: String?
  /// Canonical viewer-scoped publication identity for aggregate-feed presentation.
  public let publicationId: String?

  public init(
    entryId: String,
    title: String,
    summary: String? = nil,
    publishedAt: Date,
    thumbnailUrl: String? = nil,
    thumbnailFallbackUrl: String? = nil,
    originalUrl: String? = nil,
    publicationId: String? = nil
  ) {
    self.entryId = entryId
    self.title = title
    self.summary = summary
    self.publishedAt = publishedAt
    self.thumbnailUrl = thumbnailUrl
    self.thumbnailFallbackUrl = thumbnailFallbackUrl
    self.originalUrl = originalUrl
    self.publicationId = publicationId
  }

  public func withPublicationId(_ publicationId: String) -> AppViewEntryListItem {
    AppViewEntryListItem(
      entryId: entryId,
      title: title,
      summary: summary,
      publishedAt: publishedAt,
      thumbnailUrl: thumbnailUrl,
      thumbnailFallbackUrl: thumbnailFallbackUrl,
      originalUrl: originalUrl,
      publicationId: publicationId
    )
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
  public let feedUrls: [String]

  public init(authorDids: [String], feedUrls: [String] = []) {
    self.authorDids = authorDids
    self.feedUrls = feedUrls
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authorDids = try container.decodeIfPresent([String].self, forKey: .authorDids) ?? []
    feedUrls = try container.decodeIfPresent([String].self, forKey: .feedUrls) ?? []
  }
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
