import Foundation

public enum SportsInterestCompetitionScope {
  /// Standings describe current competition membership; event matching uses each event date separately.
  public static func competitionIDs(preferredIDs: Set<String>, catalog: [SportsEntity], now: Date) -> Set<String> {
    var selected = preferredIDs
    selected.formUnion(SportsEventPreferenceMembership.bindings(preferredIDs: preferredIDs, catalog: catalog).filter { $0.includes(now) }.map(\.entityID))
    let active = catalog.filter(\.active)
    let sports = SportsSportHierarchy.descendants(of: Set(active.filter { selected.contains($0.id) && $0.kind == "sport" }.map(\.id)), catalog: active)
    var competitions = Set(active.filter { selected.contains($0.id) }.flatMap { entity in
      entity.kind == "competition" ? [entity.id] : entity.competitionIDs
    })
    competitions.formUnion(active.filter { $0.kind == "competition" && sports.contains($0.sportID ?? "") }.map(\.id))
    var changed = true
    while changed {
      changed = false
      // Follow parent competitions down to their reviewed children, never up to siblings.
      for entity in active where entity.kind == "competition" && !competitions.isDisjoint(with: entity.competitionIDs) {
        if competitions.insert(entity.id).inserted { changed = true }
      }
    }
    return competitions
  }
}
