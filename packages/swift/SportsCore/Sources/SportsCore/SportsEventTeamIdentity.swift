import Foundation

/// Reconciles cached structured provider team names only within a reviewed competition.
/// Conflicting aliases are omitted rather than assigning an arbitrary team.
public struct SportsEventTeamIdentity: Sendable {
  public struct Binding: Codable, Sendable {
    public let competitionID: String
    public let name: String
    public let entityID: String
  }
  public let bindings: [Binding]
  private let identityByContext: [String: String]
  private let providerAbbreviationByContext: [String: String]

  public init(catalog: [SportsEntity], now: Date) {
    var candidates: [String: Set<String>] = [:]
    var components: [String: (String, String)] = [:]
    var codeOwners: [String: Set<String>] = [:]
    var providerCodes: [(context: String, codeKey: String, code: String)] = []
    for team in catalog where team.active && ["team", "ncaa-team", "national-side"].contains(team.kind) {
      let competitions = Set(team.competitionIDs + (team.memberships ?? []).filter { $0.includes(now) }.map(\.entityID))
      for competition in competitions {
        let providerCode = SportsProviderAbbreviation.validated(team.abbreviation, providerTeamID: team.providerIDs["thesportsdb"])
        for code in Set([SportsTeamAbbreviations.abbreviation(entityID: team.id), providerCode].compactMap { $0 }) {
          codeOwners[competition + "\u{0}" + code, default: []].insert(team.id)
        }
        if let providerCode {
          providerCodes.append((competition + "\u{0}" + team.id, competition + "\u{0}" + providerCode, providerCode))
        }
        for name in Set(([team.name] + team.aliases).map(Self.normalize).filter { !$0.isEmpty }) {
          let key = competition + "\u{0}" + name
          candidates[key, default: []].insert(team.id)
          components[key] = (competition, name)
        }
      }
    }
    let reviewedBindings: [Binding] = candidates.keys.sorted().compactMap { key in
      guard let ids = candidates[key], ids.count == 1, let id = ids.first, let pair = components[key] else { return nil }
      return Binding(competitionID: pair.0, name: pair.1, entityID: id)
    }
    bindings = reviewedBindings
    identityByContext = Dictionary(uniqueKeysWithValues: reviewedBindings.map { ($0.competitionID + "\u{0}" + $0.name, $0.entityID) })
    providerAbbreviationByContext = Dictionary(uniqueKeysWithValues: providerCodes.filter {
      codeOwners[$0.codeKey]?.count == 1
    }.map { ($0.context, $0.code) })
  }

  public func resolve(name: String?, competitionID: String) -> String? {
    guard let name else { return nil }
    let normalized = Self.normalize(name)
    return identityByContext[competitionID + "\u{0}" + normalized]
  }

  public func hydrate(_ event: SportsEvent) -> SportsEvent {
    let homeID = resolve(name: event.homeName, competitionID: event.competitionID)
    let awayID = resolve(name: event.awayName, competitionID: event.competitionID)
    let resolved = [homeID, awayID].compactMap { $0 }
    return SportsEvent(id: event.id, competitionID: event.competitionID, entityIDs: Array(Set(event.entityIDs + resolved)).sorted(), title: event.title, startsAt: event.startsAt, status: event.status, homeName: event.homeName, awayName: event.awayName, homeScore: event.homeScore, awayScore: event.awayScore, homeAbbreviation: abbreviation(entityID: homeID, competitionID: event.competitionID), awayAbbreviation: abbreviation(entityID: awayID, competitionID: event.competitionID), startTimeKnown: event.startTimeKnown, updatedAt: event.updatedAt)
  }

  public func hydrate(_ table: SportsStandingSnapshot) -> SportsStandingSnapshot {
    let rows = table.rows.map { row in
      SportsStandingRow(id: row.id, entityID: row.entityID ?? resolve(name: row.name, competitionID: table.competitionID), name: row.name, rank: row.rank, played: row.played, won: row.won, drawn: row.drawn, lost: row.lost, points: row.points, group: row.group, zone: row.zone)
    }
    return SportsStandingSnapshot(competitionID: table.competitionID, season: table.season, sourceURL: table.sourceURL, status: table.status, updatedAt: table.updatedAt, degraded: table.degraded, rows: rows)
  }

  private static func normalize(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

  private func abbreviation(entityID: String?, competitionID: String) -> String? {
    guard let entityID else { return nil }
    return SportsTeamAbbreviations.abbreviation(entityID: entityID)
      ?? providerAbbreviationByContext[competitionID + "\u{0}" + entityID]
  }
}
