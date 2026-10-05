import Foundation
import SportsCore
import Testing

struct SportsInterestCompetitionScopeTests {
  @Test func followsScopeSportsLeaguesTeamsAndCurrentAthletesWithoutSiblingExpansion() {
    let now = Date(timeIntervalSince1970: 1000)
    let catalog = [SportsEntity(id: "sport", name: "Sport", kind: "sport"), SportsEntity(id: "parent", name: "Parent", kind: "competition", sportID: "sport"), SportsEntity(id: "league", name: "League", kind: "competition", sportID: "sport", competitionIDs: ["parent"]), SportsEntity(id: "sibling", name: "Sibling", kind: "competition", sportID: "sport", competitionIDs: ["parent"]), SportsEntity(id: "team", name: "Team", kind: "team", competitionIDs: ["league"]), SportsEntity(id: "person", name: "Person", kind: "athlete", memberships: [.init(entityID: "team", validFrom: now.addingTimeInterval(-1))])]
    #expect(SportsInterestCompetitionScope.competitionIDs(preferredIDs: ["sport"], catalog: catalog, now: now) == ["parent", "league", "sibling"])
    for id in ["league", "team", "person"] { #expect(SportsInterestCompetitionScope.competitionIDs(preferredIDs: [id], catalog: catalog, now: now) == ["league"]) }
    #expect(SportsInterestCompetitionScope.competitionIDs(preferredIDs: ["parent"], catalog: catalog, now: now) == ["parent", "league", "sibling"])
    let nfl = SportsReviewedCatalog.id("competition:nfl")
    #expect(SportsReviewedBracketSources.matching(definition: .init(id: "sports", title: "Sports", kind: "global", description: "Sports"), catalog: SportsReviewedCatalog.entities, teamIDs: nil, preferredIDs: [nfl], now: now).map(\.competitionID) == [nfl])
  }
}
