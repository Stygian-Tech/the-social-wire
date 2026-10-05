import Testing
@testable import SportsCore

struct SportsProfessionalTeamGroupingTests {
  @Test func reviewedProfessionalGroupsAreExhaustiveUniqueAndPreserveCanonicalTeams() {
    let catalog = SportsReviewedCatalog.entities
    for (league, count) in [("NFL", 32), ("NBA", 30), ("MLB", 30), ("NHL", 32), ("MLS", 30)] {
      let competition = catalog.first { $0.name == league && $0.kind == "competition" }!
      let teams = catalog.filter { $0.kind == "team" && $0.competitionIDs.contains(competition.id) }
      let reviewed = SportsReviewedTeamGroups.groups.filter { $0.0 == league }.flatMap { $0.2 }
      #expect(teams.count == count)
      #expect(reviewed.count == count)
      #expect(Set(reviewed).count == count)
      #expect(Set(reviewed) == Set(teams.map(\.name)))
      for team in teams {
        let prefix = league == "NHL" ? ["Teams", "Hockey", "Ice Hockey", league] : ["Teams", catalog.first { $0.id == team.sportID }!.name, league]
        #expect(Array(team.groupPath?.prefix(prefix.count) ?? []) == prefix)
        #expect((team.groupPath?.count ?? 0) == (league == "NHL" ? 6 : league == "MLS" ? 4 : 5))
        let original = SportsReviewedTeams.entities.first { $0.id == team.id }!
        #expect(original.name == team.name)
        #expect(original.competitionIDs == team.competitionIDs)
        #expect(original.aliases == team.aliases)
        #expect(original.providerIDs == team.providerIDs)
      }
    }
    #expect(SportsReviewedTeamGroups.path(league: "NFL", team: "Philadelphia Eagles") == ["NFC", "East"])
    #expect(SportsReviewedTeamGroups.path(league: "MLB", team: "Athletics") == ["American League", "West"])
    #expect(SportsReviewedTeamGroups.path(league: "NHL", team: "Utah Mammoth") == ["Western Conference", "Central"])
    #expect(SportsReviewedTeamGroups.path(league: "MLS", team: "San Diego FC") == ["Western Conference"])
    #expect(SportsReviewedTeamGroups.path(league: "CFL", team: "BC Lions").isEmpty)
    #expect(SportsReviewedTeamGroups.path(league: "MLB", team: "Unreviewed Club").isEmpty)
    #expect(SportsReviewedTeamGroups.path(league: "NWSL", team: "Washington Spirit").isEmpty)
  }
}
