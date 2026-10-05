import Foundation
import WireCore

/// Internal HMAC-protected corpus contract; scores never enter public feed DTOs.
public struct FinanceSourceGeneration: Codable, Sendable {
  public let generationId: String
  public let generatedAt: Date
  public let expiresAt: Date
  public let language: String
  public let source: WirePageSource?
  public let instruments: [FinanceInstrument]
  public let candidates: [FinanceRankCandidate]
  public init(generationId: String, generatedAt: Date, expiresAt: Date, language: String,
    candidates: [FinanceRankCandidate], instruments: [FinanceInstrument] = [], source: WirePageSource? = nil) {
    self.generationId = generationId; self.generatedAt = generatedAt; self.expiresAt = expiresAt
    self.language = language; self.source = source; self.candidates = candidates; self.instruments = instruments
  }
}
