import Foundation

/// Dated team relationships let followed individuals match the team in the event's season.
public struct SportsEventPreferenceMembership: Codable, Sendable {
  public let entityID: String
  public let validFrom: Date
  public let validUntil: Date?

  public static func bindings(preferredIDs: Set<String>, catalog: [SportsEntity]) -> [Self] {
    let teams = Set(catalog.filter { $0.active && ["team", "ncaa-team", "national-side"].contains($0.kind) }.map(\.id))
    return catalog.filter { $0.active && preferredIDs.contains($0.id) && ["athlete", "driver"].contains($0.kind) }.flatMap {
      ($0.memberships ?? []).filter { teams.contains($0.entityID) }.map {
        Self(entityID: $0.entityID, validFrom: $0.validFrom, validUntil: $0.validUntil)
      }
    }
  }

  public func includes(_ date: Date) -> Bool {
    date >= validFrom && (validUntil.map { date < $0 } ?? true)
  }
}
