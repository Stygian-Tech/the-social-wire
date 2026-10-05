import Foundation

public struct FinanceCursor: Codable, Equatable, Sendable {
  public let feed: String
  public let generationID: String
  public let language: String
  public let preferenceFingerprint: String
  public let viewerScope: String
  public let nextOrdinal: Int
  public let expiresAt: Date
  public init(feed: String = "finance", generationID: String, language: String,
    preferenceFingerprint: String, viewerScope: String, nextOrdinal: Int, expiresAt: Date) {
    self.feed = feed; self.generationID = generationID; self.language = language
    self.preferenceFingerprint = preferenceFingerprint; self.viewerScope = viewerScope
    self.nextOrdinal = nextOrdinal; self.expiresAt = expiresAt
  }
}
