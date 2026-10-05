import Testing
@testable import SportsCore

struct SportsReviewedHockeyTests {
  @Test func reviewedDisciplinesAndCompetitionsRemainDistinctWithoutInventedProviderCoverage() {
    let catalog = SportsReviewedCatalog.entities
    let umbrella = SportsReviewedCatalog.id("sport:hockey")
    let disciplines = catalog.filter { $0.kind == "sport" && $0.sportID == umbrella }
    #expect(disciplines.count == 5)
    #expect(Set(disciplines.map(\.id)) == Set(SportsReviewedHockey.childSportKeys.map { SportsReviewedCatalog.id("sport:" + $0) }))
    #expect(disciplines.allSatisfy { $0.groupPath == ["Sports", "Hockey", $0.name] })
    #expect(Set(catalog.map(\.id)).count == catalog.count)
    let competitions = SportsReviewedHockey.entities
    #expect(competitions.count == 13)
    #expect(competitions.allSatisfy { $0.providerIDs.isEmpty && $0.groupPath?.prefix(2) == ["Competitions", "Hockey"] })
    for key in ["fih-pro-league", "fih-world-cup"] {
      let parent = SportsReviewedCatalog.id("competition:" + key)
      let variants = competitions.filter { $0.competitionIDs.contains(parent) }
      #expect(variants.count == 2)
      #expect(Set(variants.compactMap(\.gender)) == ["men", "women"])
    }
    let ncaa = SportsReviewedCatalog.id("competition:ncaa-womens-field-hockey")
    let divisions = competitions.filter { $0.competitionIDs.contains(ncaa) }
    #expect(divisions.count == 3)
    #expect(Set(divisions.compactMap(\.division)) == ["Division I", "Division II", "Division III"])
    #expect(divisions.allSatisfy { $0.gender == "women" && $0.sportID == SportsReviewedCatalog.id("sport:field-hockey") })
  }

  @Test func iceHockeyIdentityAndExistingTeamMappingsSurviveUmbrellaGrouping() {
    let catalog = SportsReviewedCatalog.entities
    let ice = catalog.first { $0.id == SportsReviewedCatalog.id("sport:ice-hockey") }!
    #expect(ice.name == "Ice Hockey")
    let nhl = catalog.first { $0.id == SportsReviewedCatalog.id("competition:nhl") }!
    #expect(nhl.sportID == ice.id)
    for original in SportsReviewedTeams.entities.filter({ $0.sportID == ice.id }) {
      let team = catalog.first { $0.id == original.id }!
      #expect(team.name == original.name)
      #expect(team.aliases == original.aliases)
      #expect(team.providerIDs == original.providerIDs)
      #expect(team.competitionIDs == original.competitionIDs)
      #expect(Array(team.groupPath?.prefix(4) ?? []) == ["Teams", "Hockey", "Ice Hockey", "NHL"])
    }
  }
}
