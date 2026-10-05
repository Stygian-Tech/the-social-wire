import Foundation

/// Provider-reported standings. Missing statistics are never reconstructed from event scores.
public struct SportsStandingRow: Codable, Equatable, Sendable {
  public let id: String
  public let entityID: String?
  public let name: String
  public let rank: Int?
  public let played: Int?
  public let won: Int?
  public let drawn: Int?
  public let lost: Int?
  public let points: String?
  public let group: String?
  public let zone: SportsStandingZone?

  public init(id: String, entityID: String? = nil, name: String, rank: Int? = nil,
    played: Int? = nil, won: Int? = nil, drawn: Int? = nil, lost: Int? = nil,
    points: String? = nil, group: String? = nil, zone: SportsStandingZone? = nil) {
    self.id = id; self.entityID = entityID; self.name = name; self.rank = rank
    self.played = played; self.won = won; self.drawn = drawn; self.lost = lost
    self.points = points; self.group = group; self.zone = zone
  }
  public func withZone(_ value: SportsStandingZone?) -> Self {
    .init(id: id, entityID: entityID, name: name, rank: rank, played: played, won: won,
      drawn: drawn, lost: lost, points: points, group: group, zone: value)
  }
}
