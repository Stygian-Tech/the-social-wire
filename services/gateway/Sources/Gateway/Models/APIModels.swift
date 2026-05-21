import Foundation
import GatewayCore
import Hummingbird
import GatewayCore

// ── Discovery ─────────────────────────────────────────────────────────────────

struct DiscoveredPublication: Codable, Sendable {
  let publicationId: String
  let authorDid: String
  let authorHandle: String?
  let title: String
  let avatarUrl: String?
  let discoveredAt: Date
}

struct DiscoveryResponse: Codable, Sendable {
  let publications: [DiscoveredPublication]
  let lastRefreshedAt: Date?
}

struct RefreshAcceptedResponse: Codable, Sendable {
  let status: String
  let message: String
}

// ── Content ───────────────────────────────────────────────────────────────────

struct EntryListItem: Codable, Sendable {
  let entryId: String
  let title: String
  let summary: String?
  let publishedAt: Date
  let isRead: Bool

  init(entryId: String, title: String, summary: String? = nil, publishedAt: Date, isRead: Bool = false) {
    self.entryId = entryId
    self.title = title
    self.summary = summary
    self.publishedAt = publishedAt
    self.isRead = isRead
  }
}

struct EntryListResponse: Codable, Sendable {
  let entries: [EntryListItem]
  let cursor: String?
}

struct EntryDetail: Codable, Sendable {
  let entryId: String
  let title: String
  let publishedAt: Date
  let contentHtml: String
  let originalUrl: String?
}

// ── Error ─────────────────────────────────────────────────────────────────────

struct APIError: Codable, Sendable {
  let error: String
  let message: String
}

// ── Health ────────────────────────────────────────────────────────────────────

struct HealthResponse: Codable, Sendable {
  let status: String
}

// ── ResponseEncodable conformances ────────────────────────────────────────────
// Allow route handlers to return these types directly. Hummingbird 2 encodes
// them via `context.responseEncoder` (JSONEncoder with ISO 8601 dates by default).

extension DiscoveryResponse: ResponseEncodable {}
extension EntryListResponse: ResponseEncodable {}
extension EntryDetail: ResponseEncodable {}
extension HealthResponse: ResponseEncodable {}
