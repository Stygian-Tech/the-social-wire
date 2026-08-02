import Foundation

public enum AppViewFeedKind: String, Codable, Sendable, Equatable {
  case subscribed
  case following
  case folder
  case publication

  public var requiresId: Bool {
    self == .folder || self == .publication
  }
}

public struct AppViewFeedSelector: Codable, Sendable, Equatable {
  public let kind: AppViewFeedKind
  public let id: String

  public init(kind: AppViewFeedKind, id: String? = nil) {
    self.kind = kind
    let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if kind == .folder, trimmed.hasPrefix("at://") {
      self.id = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    } else {
      self.id = trimmed
    }
  }
}

public struct AppViewViewerFeed: Codable, Sendable, Equatable {
  public let viewerDid: String
  public let kind: AppViewFeedKind
  public let feedId: String
  public let updatedAt: Date

  public init(viewerDid: String, kind: AppViewFeedKind, feedId: String, updatedAt: Date) {
    self.viewerDid = viewerDid
    self.kind = kind
    self.feedId = feedId
    self.updatedAt = updatedAt
  }
}

public struct AppViewFeedPublication: Codable, Sendable, Equatable {
  public let viewerDid: String
  public let kind: AppViewFeedKind
  public let feedId: String
  public let publicationId: String

  public init(viewerDid: String, kind: AppViewFeedKind, feedId: String, publicationId: String) {
    self.viewerDid = viewerDid
    self.kind = kind
    self.feedId = feedId
    self.publicationId = publicationId
  }
}

public struct AppViewFeedPage: Sendable {
  public let response: AppViewEntryListResponse
  public let membershipUpdatedAt: Date

  public init(response: AppViewEntryListResponse, membershipUpdatedAt: Date) {
    self.response = response
    self.membershipUpdatedAt = membershipUpdatedAt
  }
}

public enum AppViewFeedProjectionState: Sendable, Equatable {
  case available(updatedAt: Date)
  case unknown
}
