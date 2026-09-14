/// Internal Corpus Edge payload. Actor identity is never added to the public edition DTO.
/// The edition fields stay at the root so older consumers can ignore the additive map.
public struct WireCorpusEdition: Codable, Equatable, Sendable {
  public let edition: WireEdition
  public let sourceActorKeysByItemID: [String: String]?
  public let fallbackRows: [WireCorpusRow]?

  public init(edition: WireEdition, sourceActorKeysByItemID: [String: String], fallbackRows: [WireCorpusRow]? = nil) {
    self.edition = edition
    self.sourceActorKeysByItemID = sourceActorKeysByItemID
    self.fallbackRows = fallbackRows
  }

  public init(from decoder: any Decoder) throws {
    edition = try WireEdition(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceActorKeysByItemID = try container.decodeIfPresent(
      [String: String].self, forKey: .sourceActorKeysByItemID)
    fallbackRows = try container.decodeIfPresent([WireCorpusRow].self, forKey: .fallbackRows)
  }

  public func encode(to encoder: any Encoder) throws {
    try edition.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(sourceActorKeysByItemID, forKey: .sourceActorKeysByItemID)
    try container.encodeIfPresent(fallbackRows, forKey: .fallbackRows)
  }

  private enum CodingKeys: String, CodingKey {
    case sourceActorKeysByItemID
    case fallbackRows
  }
}
