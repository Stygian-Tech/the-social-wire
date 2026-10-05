import Foundation
import WireCore

public struct SportsPage: Codable, Equatable, Sendable {
  public let feedId: String
  public let generationId: String
  public let generatedAt: Date
  public let expiresAt: Date
  public let language: String
  public let preferenceRevision: String
  public let cursor: String?
  public let source: WirePageSource
  public let eventsEnabled: Bool
  public let degraded: Bool
  public let items: [SportsFeedItem]
  public init(generationId: String, generatedAt: Date, expiresAt: Date, language: String,
    preferenceRevision: String, cursor: String?, source: WirePageSource, degraded: Bool, items: [SportsFeedItem], eventsEnabled: Bool = false, feedId: String = "sports") {
    self.feedId = feedId; self.eventsEnabled = eventsEnabled; self.generationId = generationId; self.generatedAt = generatedAt; self.expiresAt = expiresAt
    self.language = language; self.preferenceRevision = preferenceRevision; self.cursor = cursor
    self.source = source; self.degraded = degraded; self.items = items
  }
}
