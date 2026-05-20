import Foundation
import Hummingbird

// MARK: - Sidebar projection DTOs

/// Scope keys for Thin AppView entry listing — mirrors web `thinAppViewClient` query params.
struct PublicationAppViewScope: Codable, Sendable, Equatable {
  let authorDid: String
  let publicationAtUri: String?
  let publicationScopeAtUris: [String]
  let publicationSiteUrls: [String]
}

/// Unified sidebar publication row returned to web and iOS clients.
struct SidebarPublicationRow: Codable, Sendable, Equatable {
  let publicationId: String
  let subscriptionPublicationId: String?
  let authorDid: String
  let authorHandle: String?
  let title: String
  let iconUrl: String?
  let avatarUrl: String?
  let discoveredAt: Date
  let appViewScope: PublicationAppViewScope
}

struct PublicationFolderRecord: Codable, Sendable {
  let uri: String
  let rkey: String
  let value: [String: AnyCodable]
}

struct PublicationPrefsRecordDTO: Codable, Sendable {
  let uri: String
  let publicationId: String
  let value: [String: AnyCodable]
}

struct PublicationSidebarResponse: Codable, Sendable {
  let viewerDid: String
  let folders: [PublicationFolderRecord]
  let publicationPrefs: [PublicationPrefsRecordDTO]
  let allPublicationRows: [SidebarPublicationRow]
  let myPublications: [SidebarPublicationRow]
  let subscribedUnfoldered: [SidebarPublicationRow]
  let followingTabPublications: [SidebarPublicationRow]
  let enrollAuthorDids: [String]
  let refreshedAt: Date
}

struct PublicationRefreshAcceptedResponse: Codable, Sendable {
  let status: String
  let refreshedAt: Date
}

// MARK: - Resolve add-publication

struct ResolveAddPublicationRequest: Codable, Sendable {
  let input: String
}

enum ResolveAddPublicationPayload: Codable, Sendable {
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

  init(from decoder: Decoder) throws {
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

  func encode(to encoder: Encoder) throws {
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

struct ResolveAddPublicationResponse: Codable, Sendable {
  let result: ResolveAddPublicationPayload?
  let error: String?
}

// MARK: - JSON helpers

/// Lossless-enough `Any` wrapper for PDS record values in API responses.
struct AnyCodable: Codable, Equatable, @unchecked Sendable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
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

  func encode(to encoder: Encoder) throws {
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

  static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
    String(describing: lhs.value) == String(describing: rhs.value)
  }
}

extension PublicationSidebarResponse: ResponseEncodable {}
extension PublicationRefreshAcceptedResponse: ResponseEncodable {}
extension ResolveAddPublicationResponse: ResponseEncodable {}
