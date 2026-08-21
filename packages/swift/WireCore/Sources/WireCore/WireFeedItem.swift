import Foundation

public struct WireFeedItem: Codable, Equatable, Sendable {
  public let itemID: String
  public let canonicalURL: String
  public let representativeURI: String?
  public let title: String
  public let summary: String?
  public let publishedAt: Date?
  public let thumbnailURL: String?
  public let source: WireItemSource
  public let reasons: [WireReasonCode]
  public let provenance: [WireProvenanceKind]

  public init(
    itemID: String,
    canonicalURL: String,
    representativeURI: String?,
    title: String,
    summary: String?,
    publishedAt: Date?,
    thumbnailURL: String?,
    source: WireItemSource,
    reasons: [WireReasonCode],
    provenance: [WireProvenanceKind]
  ) {
    self.itemID = itemID
    self.canonicalURL = canonicalURL
    self.representativeURI = representativeURI
    self.title = title
    self.summary = summary
    self.publishedAt = publishedAt
    self.thumbnailURL = thumbnailURL
    self.source = source
    self.reasons = Array(reasons.prefix(2))
    self.provenance = Array(provenance.prefix(8))
  }

  private enum CodingKeys: String, CodingKey {
    case itemID = "itemId"
    case canonicalURL = "canonicalUrl"
    case representativeURI = "representativeUri"
    case title
    case summary
    case publishedAt
    case thumbnailURL = "thumbnailUrl"
    case source
    case reasons
    case provenance
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      itemID: try container.decode(String.self, forKey: .itemID),
      canonicalURL: try container.decode(String.self, forKey: .canonicalURL),
      representativeURI: try container.decodeIfPresent(String.self, forKey: .representativeURI),
      title: try container.decode(String.self, forKey: .title),
      summary: try container.decodeIfPresent(String.self, forKey: .summary),
      publishedAt: try container.decodeIfPresent(Date.self, forKey: .publishedAt),
      thumbnailURL: try container.decodeIfPresent(String.self, forKey: .thumbnailURL),
      source: try container.decode(WireItemSource.self, forKey: .source),
      reasons: try container.decode([WireReasonCode].self, forKey: .reasons),
      provenance: try container.decode([WireProvenanceKind].self, forKey: .provenance)
    )
  }
}
