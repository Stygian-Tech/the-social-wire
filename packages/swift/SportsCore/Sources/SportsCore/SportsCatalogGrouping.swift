/// Presentation paths come from reviewed identities, never string-derived identity keys.
enum SportsCatalogGrouping {
  static func group(_ entity: SportsEntity, catalog: [String: SportsEntity]) -> SportsEntity {
    guard entity.groupPath == nil else { return entity }
    let sport = entity.sportID.flatMap { catalog[$0]?.name }
    let competition = entity.competitionIDs.first.flatMap { catalog[$0]?.name }
    let category: String
    switch entity.kind {
    case "sport": category = "Sports"
    case "competition": category = "Competitions"
    case "team": category = "Teams"
    case "national-side": category = "National Sides"
    case "driver": category = "Drivers"
    case "athlete": category = "Athletes"
    default: category = "Other"
    }
    let hockey = SportsReviewedCatalog.id("sport:hockey")
    let isHockeyChild = entity.kind == "sport" && entity.sportID == hockey
    let isHockeyMember = entity.kind != "sport" && entity.sportID.flatMap { catalog[$0]?.sportID } == hockey
    let path = (isHockeyChild ? ["Sports", "Hockey", entity.name]
      : isHockeyMember ? [category, "Hockey", sport, competition].compactMap { $0 }
      : entity.kind == "competition" && entity.name.hasPrefix("NCAA ")
      ? ["NCAA", entity.division, sport].compactMap { $0 }
      : [category, sport, competition].compactMap { $0 })
      + (entity.kind == "team" ? SportsReviewedTeamGroups.path(league: competition, team: entity.name) : [])
    return .init(id: entity.id, name: entity.name, kind: entity.kind, sportID: entity.sportID,
      competitionIDs: entity.competitionIDs, aliases: entity.aliases, providerIDs: entity.providerIDs,
      active: entity.active, memberships: entity.memberships ?? [], schoolID: entity.schoolID,
      gender: entity.gender, division: entity.division, groupPath: path, abbreviation: entity.abbreviation)
  }
}
