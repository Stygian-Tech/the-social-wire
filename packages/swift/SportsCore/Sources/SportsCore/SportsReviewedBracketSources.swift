import Foundation

public enum SportsReviewedBracketSources {
  private static let reviewedAt = Date(timeIntervalSince1970: 1791072000) // October 4, 2026 UTC.
  public static let sources: [SportsBracketSource] = [
    source("nfl", "2025", "NFL 2025 Season Playoff Bracket", "https://www.nfl.com/playoffs/bracket/2025"),
    source("nba", "2025-2026", "2026 NBA Playoff Bracket", "https://www.nba.com/playoffs/2026/bracket"),
    source("nhl", "2025-2026", "2026 NHL Playoff Central", "https://www.nhl.com/playoffs/nhl-playoff-central"),
    source("mlb", "2026", "2026 MLB Postseason Bracket", "https://www.mlb.com/postseason"),
    source("ncaa-mens-basketball", "2026", "2026 NCAA Division I Men's Basketball Bracket", "https://www.ncaa.com/march-madness-live/bracket"),
    source("ncaa-womens-basketball", "2026", "2026 NCAA Division I Women's Basketball Bracket", "https://www.ncaa.com/brackets/basketball-women/d1/2026"),
  ]

  public static func matching(definition: SportsFeedDefinition, catalog: [SportsEntity], teamIDs: Set<String>?, preferredIDs: Set<String> = [], now: Date = Date()) -> [SportsBracketSource] {
    if teamIDs?.isEmpty == true { return [] }
    let selected = SportsSportHierarchy.descendants(of: Set(definition.entityIDs), catalog: catalog)
    let related = Set(catalog.filter { selected.contains($0.id) || selected.contains($0.sportID ?? "") || !selected.isDisjoint(with: $0.competitionIDs) }.flatMap { $0.competitionIDs + ($0.kind == "competition" ? [$0.id] : []) }).union(selected)
    let teams = Set(catalog.filter { teamIDs?.contains($0.id) == true }.flatMap(\.competitionIDs))
    let preferredCompetitions = SportsInterestCompetitionScope.competitionIDs(preferredIDs: preferredIDs, catalog: catalog, now: now)
    return sources.filter { (preferredIDs.isEmpty || preferredCompetitions.contains($0.competitionID)) && (definition.id == "sports" || related.contains($0.competitionID)) && (teamIDs == nil || teams.contains($0.competitionID)) }
  }

  private static func source(_ key: String, _ season: String, _ title: String, _ url: String) -> SportsBracketSource {
    .init(id: "official:" + key + ":" + season, competitionID: SportsReviewedCatalog.id("competition:" + key), season: season, title: title, url: url, reviewedAt: reviewedAt, mode: "external")
  }
}
