import Foundation
import Hummingbird

// MARK: - Sidebar projection DTOs

public struct PublicationAppViewScope: Codable, Sendable, Equatable {
  public let authorDid: String
  public let publicationAtUri: String?
  public let publicationScopeAtUris: [String]
  public let publicationSiteUrls: [String]

  public init(
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) {
    self.authorDid = authorDid
    self.publicationAtUri = publicationAtUri
    self.publicationScopeAtUris = publicationScopeAtUris
    self.publicationSiteUrls = publicationSiteUrls
  }
}

public struct SidebarPublicationRow: Codable, Sendable, Equatable {
  public let publicationId: String
  public let subscriptionPublicationId: String?
  public let authorDid: String
  public let authorHandle: String?
  public let title: String
  public let iconUrl: String?
  public let avatarUrl: String?
  public let discoveredAt: Date
  public let appViewScope: PublicationAppViewScope
  public let unreadCount: Int?

  public init(
    publicationId: String,
    subscriptionPublicationId: String?,
    authorDid: String,
    authorHandle: String?,
    title: String,
    iconUrl: String?,
    avatarUrl: String?,
    discoveredAt: Date,
    appViewScope: PublicationAppViewScope,
    unreadCount: Int? = nil
  ) {
    self.publicationId = publicationId
    self.subscriptionPublicationId = subscriptionPublicationId
    self.authorDid = authorDid
    self.authorHandle = authorHandle
    self.title = title
    self.iconUrl = iconUrl
    self.avatarUrl = avatarUrl
    self.discoveredAt = discoveredAt
    self.appViewScope = appViewScope
    self.unreadCount = unreadCount
  }
}

public struct PublicationFolderRecord: Codable, Sendable {
  public let uri: String
  public let rkey: String
  public let value: [String: AnyCodable]

  public init(uri: String, rkey: String, value: [String: AnyCodable]) {
    self.uri = uri
    self.rkey = rkey
    self.value = value
  }
}

public struct PublicationPrefsRecordDTO: Codable, Sendable {
  public let uri: String
  public let publicationId: String
  public let value: [String: AnyCodable]

  public init(uri: String, publicationId: String, value: [String: AnyCodable]) {
    self.uri = uri
    self.publicationId = publicationId
    self.value = value
  }
}

public struct PublicationFolderSection: Codable, Sendable, Equatable {
  public let folderUri: String
  public let folderRkey: String
  public let name: String
  public let publications: [SidebarPublicationRow]
  public let unreadCount: Int

  public init(
    folderUri: String,
    folderRkey: String,
    name: String,
    publications: [SidebarPublicationRow],
    unreadCount: Int
  ) {
    self.folderUri = folderUri
    self.folderRkey = folderRkey
    self.name = name
    self.publications = publications
    self.unreadCount = unreadCount
  }
}

public struct PublicationSidebarResponse: Codable, Sendable {
  public let viewerDid: String
  public let folders: [PublicationFolderRecord]
  public let publicationPrefs: [PublicationPrefsRecordDTO]
  public let folderSections: [PublicationFolderSection]
  public let allPublicationRows: [SidebarPublicationRow]
  public let myPublications: [SidebarPublicationRow]
  public let subscribedUnfoldered: [SidebarPublicationRow]
  public let followingTabPublications: [SidebarPublicationRow]
  public let enrollAuthorDids: [String]
  public let totalUnreadCount: Int
  public let refreshedAt: Date

  public init(
    viewerDid: String,
    folders: [PublicationFolderRecord],
    publicationPrefs: [PublicationPrefsRecordDTO],
    folderSections: [PublicationFolderSection],
    allPublicationRows: [SidebarPublicationRow],
    myPublications: [SidebarPublicationRow],
    subscribedUnfoldered: [SidebarPublicationRow],
    followingTabPublications: [SidebarPublicationRow],
    enrollAuthorDids: [String],
    totalUnreadCount: Int,
    refreshedAt: Date
  ) {
    self.viewerDid = viewerDid
    self.folders = folders
    self.publicationPrefs = publicationPrefs
    self.folderSections = folderSections
    self.allPublicationRows = allPublicationRows
    self.myPublications = myPublications
    self.subscribedUnfoldered = subscribedUnfoldered
    self.followingTabPublications = followingTabPublications
    self.enrollAuthorDids = enrollAuthorDids
    self.totalUnreadCount = totalUnreadCount
    self.refreshedAt = refreshedAt
  }
}

public struct PublicationRefreshAcceptedResponse: Codable, Sendable {
  public let status: String
  public let refreshedAt: Date

  public init(status: String, refreshedAt: Date) {
    self.status = status
    self.refreshedAt = refreshedAt
  }
}

public struct ResolveAddPublicationRequest: Codable, Sendable {
  public let input: String

  public init(input: String) {
    self.input = input
  }
}

public enum ResolveAddPublicationPayload: Codable, Sendable {
  case standardSite(publicationAtUri: String)
  case rss(feedUrl: String, title: String?, siteUrl: String?, feedIconUrl: String?)

  enum CodingKeys: String, CodingKey {
    case kind
    case publicationAtUri
    case feedUrl
    case title
    case siteUrl
    case feedIconUrl
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(String.self, forKey: .kind)
    switch kind {
    case "standard-site":
      self = .standardSite(publicationAtUri: try c.decode(String.self, forKey: .publicationAtUri))
    case "rss":
      self = .rss(
        feedUrl: try c.decode(String.self, forKey: .feedUrl),
        title: try c.decodeIfPresent(String.self, forKey: .title),
        siteUrl: try c.decodeIfPresent(String.self, forKey: .siteUrl),
        feedIconUrl: try c.decodeIfPresent(String.self, forKey: .feedIconUrl)
      )
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown kind")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .standardSite(publicationAtUri):
      try c.encode("standard-site", forKey: .kind)
      try c.encode(publicationAtUri, forKey: .publicationAtUri)
    case let .rss(feedUrl, title, siteUrl, feedIconUrl):
      try c.encode("rss", forKey: .kind)
      try c.encode(feedUrl, forKey: .feedUrl)
      try c.encodeIfPresent(title, forKey: .title)
      try c.encodeIfPresent(siteUrl, forKey: .siteUrl)
      try c.encodeIfPresent(feedIconUrl, forKey: .feedIconUrl)
    }
  }
}

public struct ResolveAddPublicationResponse: Codable, Sendable {
  public let result: ResolveAddPublicationPayload?
  public let error: String?

  public init(result: ResolveAddPublicationPayload?, error: String?) {
    self.result = result
    self.error = error
  }
}

public struct AnyCodable: Codable, Equatable, @unchecked Sendable {
  public let value: Any

  public init(_ value: Any) {
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let b = try? container.decode(Bool.self) { value = b; return }
    if let i = try? container.decode(Int.self) { value = i; return }
    if let d = try? container.decode(Double.self) { value = d; return }
    if let s = try? container.decode(String.self) { value = s; return }
    if let a = try? container.decode([AnyCodable].self) { value = a.map(\.value); return }
    if let o = try? container.decode([String: AnyCodable].self) {
      value = o.mapValues(\.value)
      return
    }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case let b as Bool: try container.encode(b)
    case let i as Int: try container.encode(i)
    case let d as Double: try container.encode(d)
    case let s as String: try container.encode(s)
    case let a as [Any]:
      try container.encode(a.map { AnyCodable($0) })
    case let o as [String: Any]:
      try container.encode(o.mapValues { AnyCodable($0) })
    default:
      try container.encode(String(describing: value))
    }
  }

  public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
    String(describing: lhs.value) == String(describing: rhs.value)
  }
}

extension PublicationSidebarResponse: ResponseEncodable {}
extension PublicationRefreshAcceptedResponse: ResponseEncodable {}
extension ResolveAddPublicationResponse: ResponseEncodable {}
