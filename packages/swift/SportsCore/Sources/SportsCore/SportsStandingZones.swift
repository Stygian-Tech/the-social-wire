import Foundation

public enum SportsStandingZones {
  /// Preserve the provider's wording, including promotion/relegation play-offs.
  public static func provider(description: String?, sourceURL: String) -> SportsStandingZone? {
    guard let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 512 else { return nil }
    let normalized = text.lowercased()
    let kind: String
    if normalized.contains("relegation") { kind = "relegation" }
    else if normalized.contains("play off") || normalized.contains("play-off") || normalized.contains("playoff") { kind = "playoff" }
    else if normalized.contains("champions league") || normalized.contains("europa league") || normalized.contains("conference league")
      || normalized.contains("copa libertadores") || normalized.contains("copa sudamericana") || normalized.contains("qualif") { kind = "qualification" }
    else if normalized.contains("promotion") { kind = "promotion" }
    else { return nil }
    return .init(kind: kind, label: text, sourceURL: sourceURL)
  }

  /// Hydrates retained pre-zone snapshots with reviewed 2026/27 places only.
  /// Rules are deliberately season-bound and require a complete ungrouped table.
  public static func reviewed(_ table: SportsStandingSnapshot) -> SportsStandingSnapshot {
    guard table.season == "2026-2027", table.rows.allSatisfy({ $0.group == nil || $0.group == "" }) else { return table }
    let premier = table.competitionID == SportsReviewedCatalog.id("competition:premier-league")
    let championship = table.competitionID == SportsReviewedCatalog.id("competition:efl-championship")
    let expected = premier ? 20 : championship ? 24 : 0
    guard expected > 0, table.rows.count == expected,
      Set(table.rows.compactMap(\.rank)) == Set(1...expected) else { return table }
    let premierSource = "https://www.premierleague.com/en/news/4365156"
    let playoffSource = "https://www.efl.com/news/2026/march/05/efl-statement--sky-bet-championship-play-off-format/"
    let rows = table.rows.map { row -> SportsStandingRow in
      guard row.zone == nil, let rank = row.rank else { return row }
      let zone: SportsStandingZone?
      if premier, rank >= 18 { zone = .init(kind: "relegation", label: "Relegation Places", sourceURL: premierSource) }
      else if championship, rank <= 2 { zone = .init(kind: "promotion", label: "Automatic Promotion Places", sourceURL: premierSource) }
      else if championship, (3...8).contains(rank) { zone = .init(kind: "playoff", label: "Promotion Play-Off Places", sourceURL: playoffSource) }
      else { zone = nil }
      return row.withZone(zone)
    }
    return .init(competitionID: table.competitionID, season: table.season, sourceURL: table.sourceURL,
      status: table.status, updatedAt: table.updatedAt, degraded: table.degraded, rows: rows)
  }
}
