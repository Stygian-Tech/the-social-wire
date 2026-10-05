import Foundation
import Testing
@testable import SportsCore

struct SportsProviderTimestampTests {
  @Test func providerUTCAndExplicitOffsetsIdentifyTheSameInstant() {
    let utc = SportsProviderTimestamp.parse("2026-10-04T20:05:00Z")
    #expect(utc != nil)
    #expect(SportsProviderTimestamp.parse("2026-10-04T20:05:00") == utc)
    #expect(SportsProviderTimestamp.parse("2026-10-04T16:05:00-04:00") == utc)
    #expect(SportsProviderTimestamp.parse("2026-10-04T20:05:00.000") == utc)
    #expect(SportsProviderTimestamp.parse("2026-10-04T20:05:00.000Z") == utc)
    #expect(SportsProviderTimestamp.parse("not a timestamp") == nil)
    #expect(SportsProviderTimestamp.parse("") == nil)
  }

  @Test func actualProviderShapeSupportsFixturesAndRaces() {
    let now = Date()
    let fixture = TheSportsDBAdapter.event(["idEvent": "1", "strEvent": "NFL fixture", "strTimestamp": "2026-10-04T20:05:00"], competitionID: "nfl", entities: [], now: now)
    let race = TheSportsDBAdapter.event(["idEvent": "2", "strEvent": "Grand Prix", "strTimestamp": "2026-10-09T08:30:00"], competitionID: "f1", entities: [], now: now)
    #expect(fixture?.startsAt == SportsProviderTimestamp.parse("2026-10-04T20:05:00Z"))
    #expect(race?.title == "Grand Prix")
    #expect(race?.entityIDs.isEmpty == true)
    #expect(race?.homeName == nil)
  }

  @Test func unknownProviderStartTimeIsExplicitAndActualMidnightRemainsKnown() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let base = ["idEvent": "1", "strEvent": "Fixture", "dateEvent": "2026-10-05"]
    func event(_ values: [String: String]) -> SportsEvent? {
      TheSportsDBAdapter.event(base.merging(values, uniquingKeysWith: { _, new in new }), competitionID: "league", entities: [], now: now)
    }
    let missing = try #require(event([:]))
    #expect(missing.startTimeKnown == false)
    #expect(event(["strTime": ""])?.startTimeKnown == false)
    #expect(event(["strTime": "TBD"])?.startTimeKnown == false)
    #expect(event(["strTime": "25:99:00"])?.startTimeKnown == false)
    #expect(event(["strTime": "00:00:00"])?.startTimeKnown == true)
    #expect(event(["strTime": "00:00"])?.startTimeKnown == true)
    #expect(event(["strTime": "00:00:00"])?.startsAt == missing.startsAt)
    #expect(event(["strTimestamp": "2026-10-05T00:00:00Z"])?.startTimeKnown == true)
    #expect(event(["strTimestamp": "invalid", "strTime": "14:30:00"])?.startTimeKnown == true)
    #expect(SportsEventTeamIdentity(catalog: [], now: now).hydrate(missing).startTimeKnown == false)
    let legacy = SportsEvent(id: "legacy", competitionID: "league", title: "Fixture", startsAt: now, status: "scheduled", updatedAt: now)
    #expect(try JSONDecoder().decode(SportsEvent.self, from: JSONEncoder().encode(legacy)).startTimeKnown == nil)
  }

}
