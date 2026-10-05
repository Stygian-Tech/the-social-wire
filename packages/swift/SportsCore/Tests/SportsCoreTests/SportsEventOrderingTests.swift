import Foundation
import Testing
@testable import SportsCore

struct SportsEventOrderingTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func activeAndRecentResultsPrecedeNearbyFixtures() {
    let upcoming = event("next", offset: 30, status: "scheduled")
    let active = event("active", offset: -8 * 3600, status: "in-progress")
    let recent = event("recent", offset: -3600, status: "finished")
    let old = event("old", offset: -25 * 3600, status: "finished")
    #expect([old, upcoming, recent, active].sorted { SportsEventOrdering.precedes($0, $1, now: now) }.map(\.id) == ["active", "recent", "next", "old"])
  }

  @Test func upcomingCoveragePrecedesOlderHistoricalResults() {
    let history = event("history", offset: -3 * 86400, status: "finished")
    let future = event("future", offset: 4 * 86400, status: "scheduled")
    let postponed = event("postponed", offset: 5 * 86400, status: "postponed")
    #expect([history, postponed, future].sorted { SportsEventOrdering.precedes($0, $1, now: now) }.map(\.id) == ["future", "postponed", "history"])
  }

  @Test func refreshTimeCannotMakeHistoricalResultsRecent() {
    #expect(!SportsEventOrdering.isRecentResult(event("old", offset: -25 * 3600, status: "finished"), now: now))
    #expect(!SportsEventOrdering.isRecentResult(event("future", offset: 1, status: "finished"), now: now))
    #expect(!SportsEventOrdering.isRecentResult(event("cancelled", offset: -1, status: "cancelled"), now: now))
    #expect(!SportsEventOrdering.isRecentResult(event("boundary", offset: -24 * 3600, status: "finished"), now: now))
  }

  @Test func equalDistancesAndDatesHaveDeterministicTies() {
    let past = event("past", offset: -60, status: "scheduled")
    let future = event("future", offset: 60, status: "scheduled")
    let sameA = event("a", offset: 60, status: "scheduled")
    #expect(SportsEventOrdering.precedes(future, past, now: now))
    #expect(SportsEventOrdering.precedes(sameA, future, now: now))
    #expect(!SportsEventOrdering.precedes(sameA, sameA, now: now))
  }

  @Test func viewerCalendarDayControlsFinalResultProminence() {
    let current = ISO8601DateFormatter().date(from: "2026-10-04T01:00:00Z")!
    let start = ISO8601DateFormatter().date(from: "2026-10-03T23:00:00Z")!
    let result = SportsEvent(id: "result", competitionID: "league", title: "Result", startsAt: start, status: "finished", updatedAt: current)
    #expect(!SportsEventOrdering.isRecentResult(result, now: current))
    #expect(SportsEventOrdering.isRecentResult(result, now: current, timeZone: TimeZone(identifier: "America/New_York")!))
  }

  @Test func directInterestsLeadCompetitionsThenSportsWithinAnActivityGroup() {
    let catalog: [SportsEntity] = [
      .init(id: "team", name: "Team", kind: "team", sportID: "sport", competitionIDs: ["league"]),
      .init(id: "person", name: "Person", kind: "athlete", sportID: "sport", competitionIDs: ["league"]),
      .init(id: "league", name: "League", kind: "competition", sportID: "sport"),
      .init(id: "other-league", name: "Other League", kind: "competition", sportID: "sport"),
      .init(id: "sport", name: "Sport", kind: "sport")
    ]
    let direct = SportsEvent(id: "direct", competitionID: "league", entityIDs: ["team"], title: "Direct", startsAt: now.addingTimeInterval(4 * 86400), status: "scheduled", updatedAt: now)
    let person = SportsEvent(id: "person", competitionID: "league", entityIDs: ["person"], title: "Person", startsAt: now.addingTimeInterval(3 * 86400), status: "scheduled", updatedAt: now)
    let league = SportsEvent(id: "league", competitionID: "league", title: "League", startsAt: now.addingTimeInterval(2 * 86400), status: "scheduled", updatedAt: now)
    let sport = SportsEvent(id: "sport", competitionID: "other-league", title: "Sport", startsAt: now.addingTimeInterval(3600), status: "scheduled", updatedAt: now)
    let unrelated = SportsEvent(id: "none", competitionID: "unrelated", title: "None", startsAt: now.addingTimeInterval(1), status: "scheduled", updatedAt: now)
    let preferred: Set<String> = ["team", "person", "league", "sport"]
    #expect([unrelated, sport, league, direct, person].sorted { SportsEventOrdering.precedes($0, $1, now: now, preferredIDs: preferred, catalog: catalog) }.map(\.id) == ["person", "direct", "league", "sport", "none"])
    #expect(SportsEventOrdering.sorted([unrelated, sport, league, direct, person], now: now, preferredIDs: preferred, catalog: catalog).map(\.id) == ["person", "direct", "league", "sport", "none"])
    let active = event("active", offset: -3600, status: "in-progress")
    #expect(SportsEventOrdering.precedes(active, direct, now: now, preferredIDs: preferred, catalog: catalog))
  }

  @Test func athleteTeamPreferenceUsesEffectiveDatedMembershipOnly() {
    let team = SportsEntity(id: "team", name: "Team", kind: "team")
    let athlete = SportsEntity(id: "athlete", name: "Athlete", kind: "athlete", memberships: [.init(entityID: "team", validFrom: now.addingTimeInterval(-3600), validUntil: now.addingTimeInterval(3600))])
    let match = SportsEvent(id: "match", competitionID: "league", entityIDs: ["team"], title: "Match", startsAt: now, status: "scheduled", updatedAt: now)
    let later = SportsEvent(id: "later", competitionID: "league", entityIDs: ["team"], title: "Later", startsAt: now.addingTimeInterval(3600), status: "scheduled", updatedAt: now)
    #expect(SportsEventOrdering.interestTier(match, preferredIDs: ["athlete"], catalog: [team, athlete]) == 0)
    #expect(SportsEventOrdering.interestTier(later, preferredIDs: ["athlete"], catalog: [team, athlete]) == 3)
  }

  private func event(_ id: String, offset: TimeInterval, status: String) -> SportsEvent {
    .init(id: id, competitionID: "league", title: id, startsAt: now.addingTimeInterval(offset), status: status, updatedAt: now)
  }
}
