import Foundation
import Testing
@testable import SportsCore

struct SportsStandingZoneTests {
  @Test func providerAnnotationsAreAutomaticWithoutInventingOutcomes() {
    for (description,kind) in [
      ("Promotion - Premier League","promotion"),
      ("Promotion - Championship (Play Offs: Quarter-finals)","playoff"),
      ("Promotion - MLS (Play Offs: 1/8-finals)","playoff"),
      ("Promotion - Champions League (League phase)","qualification"),
      ("Relegation Playoffs","relegation")
    ] {
      let zone = SportsStandingZones.provider(description: description, sourceURL: "https://www.thesportsdb.com/table.php?l=4329&s=2026-2027")
      #expect(zone?.kind == kind)
      #expect(zone?.label == description)
    }
    #expect(SportsStandingZones.provider(description: "", sourceURL: "https://www.thesportsdb.com/") == nil)
    #expect(SportsStandingZones.provider(description: "No reviewed outcome", sourceURL: "https://www.thesportsdb.com/") == nil)
  }

  @Test func championshipSixClubPlayoffAndRelegationBoundariesAreSeasonBound() {
    let table = fixture("efl-championship", count: 24)
    let rows = SportsStandingZones.reviewed(table).rows
    #expect(rows[1].zone?.kind == "promotion")
    #expect(rows[2].zone?.kind == "playoff")
    #expect(rows[7].zone?.kind == "playoff")
    #expect(rows[8].zone == nil)
    #expect(rows[20].zone == nil)
    #expect(rows[21].zone == nil) // Current provider supplies relegation annotations; no historical-rule guess.
    #expect(rows[23].zone == nil)
    #expect(rows[7].points == table.rows[7].points)
    #expect(SportsStandingZones.reviewed(fixture("efl-championship", count: 24, season: "2025-2026")).rows.allSatisfy { $0.zone == nil })
  }

  @Test func premierBottomThreeAndCompleteTableGuards() {
    let rows = SportsStandingZones.reviewed(fixture("premier-league", count: 20)).rows
    #expect(rows[16].zone == nil)
    #expect(rows[17].zone?.kind == "relegation")
    #expect(rows[19].zone?.kind == "relegation")
    #expect(rows[0].zone == nil) // Leader is not declared champion mid-season.
    #expect(SportsStandingZones.reviewed(fixture("premier-league", count: 19)).rows.allSatisfy { $0.zone == nil })
    #expect(SportsStandingZones.reviewed(fixture("efl-league-one", count: 24)).rows.allSatisfy { $0.zone == nil })
    #expect(SportsStandingZones.reviewed(fixture("efl-league-two", count: 24)).rows.allSatisfy { $0.zone == nil })
  }

  @Test func eflProviderRowsRetainExactPlayoffStagesAndRelegationLabels() throws {
    for (rank,description,kind) in [(3,"Promotion - League One (Play Offs)","playoff"),(21,"Relegation - League Two","relegation"),(3,"Promotion - League One","promotion"),(23,"Relegation - National League","relegation")] {
      let row = try #require(TheSportsDBAdapter.standing(["idTeam":"1","strTeam":"Fixture","intRank":String(rank),"strDescription":description], competitionID: "league", entities: []))
      #expect(row.zone?.kind == kind)
      #expect(row.zone?.label == description)
    }
  }

  private func fixture(_ league: String, count: Int, season: String = "2026-2027") -> SportsStandingSnapshot {
    .init(competitionID: SportsReviewedCatalog.id("competition:" + league), season: season, status: "available",
      rows: (1...count).map { .init(id: String($0), name: "Club \($0)", rank: $0, points: String(50-$0)) })
  }
}
