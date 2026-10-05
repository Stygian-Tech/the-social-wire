import Foundation
import Testing
@testable import SportsCore

struct SportsEventTeamIdentityTests {
  @Test func requiresExactUniqueCompetitionContext() {
    let now = Date()
    let eagle = SportsEntity(id: "eagles", name: "Philadelphia Eagles", kind: "team", competitionIDs: ["nfl"], aliases: ["Eagles"])
    let unrelated = SportsEntity(id: "other-eagles", name: "Eagles", kind: "team", competitionIDs: ["rugby"])
    let identity = SportsEventTeamIdentity(catalog: [eagle, unrelated], now: now)
    #expect(identity.resolve(name: "  PHILADELPHIA EAGLES ", competitionID: "nfl") == eagle.id)
    #expect(identity.resolve(name: "Eagles", competitionID: "rugby") == unrelated.id)
    #expect(identity.resolve(name: "Eagles beat Giants", competitionID: "nfl") == nil)
    #expect(identity.resolve(name: "Eagles", competitionID: "unknown") == nil)
    let collision = SportsEntity(id: "collision", name: "Eagles", kind: "team", competitionIDs: ["nfl"])
    #expect(SportsEventTeamIdentity(catalog: [eagle, collision], now: now).resolve(name: "Eagles", competitionID: "nfl") == nil)
  }

  @Test func reconcilesWithoutChangingScoresRanksOrExistingIdentity() {
    let now = Date()
    let identity = SportsEventTeamIdentity(catalog: [.init(id: "eagles", name: "Eagles", kind: "team", competitionIDs: ["nfl"])], now: now)
    let event = SportsEvent(id: "fixture", competitionID: "nfl", title: "Eagles game", startsAt: now, status: "finished", homeName: "Eagles", homeScore: "21", updatedAt: now)
    #expect(identity.hydrate(event).entityIDs == ["eagles"])
    #expect(identity.hydrate(event).homeScore == "21")
    let table = SportsStandingSnapshot(competitionID: "nfl", season: "2026", status: "available", rows: [.init(id: "provider", name: "Eagles", rank: 7, points: "12.5", zone: .init(kind: "playoff", label: "Provider Play-Off", sourceURL: "https://www.thesportsdb.com/")), .init(id: "verified", entityID: "different", name: "Eagles", rank: 8)])
    #expect(identity.hydrate(table).rows[0].entityID == "eagles")
    #expect(identity.hydrate(table).rows[0].rank == 7)
    #expect(identity.hydrate(table).rows[0].zone == table.rows[0].zone)
    #expect(identity.hydrate(table).rows[1].entityID == "different")
  }

  @Test func largeCatalogHydratesServingLimitAndKeepsCollisionIsolation() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var catalog = (0..<12131).map { number in
      SportsEntity(id: "team-\(number)", name: "Team \(number)", kind: "team", competitionIDs: ["league"], aliases: ["Alias \(number)"])
    }
    catalog.append(.init(id: "collision", name: "Alias 12130", kind: "team", competitionIDs: ["league"]))
    let identity = SportsEventTeamIdentity(catalog: catalog, now: now)
    #expect(identity.resolve(name: "Alias 12130", competitionID: "league") == nil)
    #expect(identity.resolve(name: "Team 12130", competitionID: "other-league") == nil)
    let events = (0..<500).map { number in
      SportsEvent(id: "event-\(number)", competitionID: "league", title: "Fixture \(number)", startsAt: now,
        status: "finished", homeName: "Team 12130", awayName: "Alias 12129", homeScore: "2", awayScore: "1", updatedAt: now)
    }
    let hydrated = events.map(identity.hydrate)
    #expect(hydrated.count == 500)
    #expect(hydrated.allSatisfy { $0.entityIDs == ["team-12129", "team-12130"] && $0.homeScore == "2" && $0.awayScore == "1" })
    #expect(hydrated.map(\.id) == events.map(\.id))
  }

}
