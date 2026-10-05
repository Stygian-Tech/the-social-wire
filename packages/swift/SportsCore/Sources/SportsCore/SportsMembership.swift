import Foundation

/// Time-bounded membership preserves identity across transfers and season changes.
public struct SportsMembership: Codable, Equatable, Sendable {
  public let entityID: String
  public let validFrom: Date
  public let validUntil: Date?
  public let season: String?
  public init(entityID: String, validFrom: Date, validUntil: Date? = nil, season: String? = nil) {
    self.entityID = entityID; self.validFrom = validFrom; self.validUntil = validUntil; self.season = season
  }
  public func includes(_ date: Date) -> Bool { date >= validFrom && (validUntil.map { date < $0 } ?? true) }

  private enum CodingKeys: String, CodingKey { case entityID, validFrom, validUntil, season }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    entityID = try values.decode(String.self, forKey: .entityID)
    validFrom = try Self.date(values, key: .validFrom)
    if values.contains(.validUntil) {
      validUntil = try values.decodeNil(forKey: .validUntil) ? nil : Self.date(values, key: .validUntil)
    } else { validUntil = nil }
    season = try values.decodeIfPresent(String.self, forKey: .season)
  }
  /// Private Postgres catalog JSON uses Swift reference dates; public/corpus JSON uses ISO8601.
  private static func date(_ values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date {
    if let number = try? values.decode(Double.self, forKey: key) { return Date(timeIntervalSinceReferenceDate: number) }
    let string = try values.decode(String.self, forKey: key)
    // Value-style parsers avoid allocating an ICU-backed formatter for each catalog membership.
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
    if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Invalid membership date")
  }
}
