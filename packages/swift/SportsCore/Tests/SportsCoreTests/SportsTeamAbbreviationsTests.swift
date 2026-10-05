import Foundation
import Testing
@testable import SportsCore

struct SportsTeamAbbreviationsTests {
  @Test func canonicalReviewedCodesAreCompetitionScopedAndNeverGuessedFromAliases() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let catalog = SportsReviewedCatalog.entities
    let identity = SportsEventTeamIdentity(catalog: catalog, now: now)
    let event = SportsEvent(id: "e", competitionID: SportsReviewedCatalog.id("competition:nfl"), title: "Eagles vs Rams", startsAt: now, status: "scheduled", homeName: "Philadelphia Eagles", awayName: "Los Angeles Rams", updatedAt: now)
    let hydrated = identity.hydrate(event)
    #expect(hydrated.homeAbbreviation == "PHI")
    #expect(hydrated.awayAbbreviation == "LAR")
    #expect(hydrated.homeName == event.homeName)
    #expect(hydrated.title == event.title)
    let wrongCompetition = SportsEvent(id: "wrong", competitionID: SportsReviewedCatalog.id("competition:mlb"), title: "Eagles vs Rams", startsAt: now, status: "scheduled", homeName: event.homeName, awayName: event.awayName, updatedAt: now)
    #expect(identity.hydrate(wrongCompetition).homeAbbreviation == nil)
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:mlb:Athletics")) == "ATH")
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:nhl:Philadelphia Flyers")) == "PHI")
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:premier-league:Liverpool")) == nil)
    let decoded = try JSONDecoder().decode(SportsEvent.self, from: JSONEncoder().encode(hydrated))
    #expect(decoded == hydrated)
    let legacy = try JSONDecoder().decode(SportsEvent.self, from: JSONEncoder().encode(event))
    #expect(legacy.homeAbbreviation == nil)
  }

  @Test func reviewedSchoolAndMarchingArtsCodesPreserveDistinctCanonicalPrograms() {
    let catalog = SportsReviewedCatalog.entities
    let schoolIDs = Set(SportsReviewedAmateurAbbreviations.schoolCodes.keys.map { SportsReviewedCatalog.id("school:" + $0) })
    let teams = catalog.filter { $0.kind == "ncaa-team" && $0.schoolID.map(schoolIDs.contains) == true }
    #expect(teams.count > 8)
    for team in teams {
      let school = catalog.first { $0.id == team.schoolID }!
      #expect(SportsTeamAbbreviations.abbreviation(entityID: team.id) == SportsReviewedAmateurAbbreviations.schoolCodes[school.name])
    }
    for (name, code) in [("United Percussion", "UPW"), ("United Percussion 2", "UP2"), ("RCC", "RCC"), ("Blue Knights", "BKPE")] {
      let id = SportsReviewedCatalog.id(SportsReviewedWGI.groupKey(discipline: "percussion", format: "Marching", name: name))
      #expect(catalog.contains { $0.id == id })
      #expect(SportsTeamAbbreviations.abbreviation(entityID: id) == code)
    }
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:dci:blue-knights")) == "BK")
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:dci:santa-clara-vanguard")) == "SCV")
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:dci:boston-crusaders")) == "BAC")
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:dci:blue-devils-b")) == nil)
    #expect(SportsTeamAbbreviations.abbreviation(entityID: SportsReviewedCatalog.id("team:dci:bluecoats")) == nil)
    print("Reviewed amateur abbreviation coverage: \(teams.count) NCAA teams across \(schoolIDs.count) schools; 5 DCI corps; 4 WGI ensembles")
  }

}
