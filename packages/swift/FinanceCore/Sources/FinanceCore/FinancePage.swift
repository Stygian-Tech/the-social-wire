import Foundation
import WireCore

public struct FinancePage: Codable, Equatable, Sendable {
  public let feedId: String
  public let generationId: String
  public let generatedAt: Date
  public let expiresAt: Date
  public let language: String
  public let preferenceRevision: String
  public let cursor: String?
  public let source: WirePageSource
  public let widgetsEnabled: Bool
  public let degraded: Bool
  public let items: [FinanceFeedItem]
  public init(generationId: String, generatedAt: Date, expiresAt: Date, language: String,
    preferenceRevision: String, cursor: String?, source: WirePageSource, degraded: Bool, items: [FinanceFeedItem], widgetsEnabled: Bool = false, feedId: String = "finance") {
    self.feedId = feedId; self.widgetsEnabled = widgetsEnabled; self.generationId = generationId; self.generatedAt = generatedAt; self.expiresAt = expiresAt
    self.language = language; self.preferenceRevision = preferenceRevision; self.cursor = cursor
    self.source = source; self.degraded = degraded; self.items = items
  }
}
