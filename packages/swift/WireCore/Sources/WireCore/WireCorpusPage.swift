import Foundation

public struct WireCorpusPage: Codable, Equatable, Sendable {
  public let generationID: String
  public let generatedAt: Date
  public let language: String
  public let source: WirePageSource
  public let degraded: Bool
  public let rows: [WireCorpusRow]
  public let exhausted: Bool

  public init(
    generationID: String,
    generatedAt: Date,
    language: String,
    source: WirePageSource,
    degraded: Bool,
    rows: [WireCorpusRow],
    exhausted: Bool
  ) {
    self.generationID = generationID
    self.generatedAt = generatedAt
    self.language = language
    self.source = source
    self.degraded = degraded
    self.rows = Array(rows.prefix(500))
    self.exhausted = exhausted
  }

  private enum CodingKeys: String, CodingKey {
    case generationID = "generationId"
    case generatedAt
    case language
    case source
    case degraded
    case rows
    case exhausted
  }
}
