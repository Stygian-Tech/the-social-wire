import Foundation
import WireCore

/// Internal HMAC-protected corpus contract; scores never enter public feed DTOs.
public struct SportsSourceGeneration: Codable, Sendable {
  public let generationId: String
  public let generatedAt: Date
  public let expiresAt: Date
  public let language: String
  public let source: WirePageSource?
  public let entities: [SportsEntity]
  public let candidates: [SportsRankCandidate]
  public init(generationId: String, generatedAt: Date, expiresAt: Date, language: String,
    candidates: [SportsRankCandidate], entities: [SportsEntity] = [], source: WirePageSource? = nil) {
    self.generationId = generationId; self.generatedAt = generatedAt; self.expiresAt = expiresAt
    self.language = language; self.source = source; self.candidates = candidates; self.entities = entities
  }
}
