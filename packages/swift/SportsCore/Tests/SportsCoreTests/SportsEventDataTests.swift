import Foundation
import Testing
@testable import SportsCore

struct SportsEventDataTests {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  @Test func standingsPreserveProviderDecimalsAndScopeIdentity() throws {
    let correct = SportsEntity(id: "club", name: "Club", kind: "team", competitionIDs: ["league"], providerIDs: ["thesportsdb": "1"])
    let wrong = SportsEntity(id: "person", name: "Person", kind: "athlete", competitionIDs: ["league"], providerIDs: ["thesportsdb": "1"])
    let other = SportsEntity(id: "other", name: "Other", kind: "team", competitionIDs: ["other"], providerIDs: ["thesportsdb": "1"])
    let row = try #require(TheSportsDBAdapter.standing(["idTeam": "1", "strTeam": "Club", "intRank": "2", "intPoints": "12.5", "intWin": "3", "intLoss": "-1"], competitionID: "league", entities: [correct, wrong, other]))
    #expect(row.entityID == "club")
    #expect(row.points == "12.5")
    #expect(row.rank == 2)
    #expect(row.won == 3)
    #expect(row.lost == nil)
    #expect(TheSportsDBAdapter.standing(["idTeam": "1"], competitionID: "league", entities: []) == nil)
  }

  @Test func seasonalScheduleUsesDocumentedEndpointAndRejectsUnreviewableInput() async throws {
    let adapter = TheSportsDBAdapter(apiKey: "fixture") { request in
      #expect(request.url?.path == "/api/v2/json/schedule/league/4328/2026-2027")
      #expect(request.value(forHTTPHeaderField: "X-API-KEY") == "fixture")
      return (Data("{\"schedule\":null}".utf8), 200)
    }
    #expect(try await adapter.seasonEvents(providerLeagueID: "4328", season: "2026-2027", competitionID: "league", entities: [], now: now).isEmpty)
    await #expect(throws: SportsProviderError.invalidResponse) {
      try await adapter.seasonEvents(providerLeagueID: "../4328", season: "2026-2027", competitionID: "league", entities: [], now: now)
    }
  }

  @Test func tableEmptyIsSuccessfulButMalformedResponsePreservesPriorSnapshot() async throws {
    let empty = TheSportsDBAdapter(apiKey: "fixture") { request in
      #expect(request.url?.path == "/api/v1/json/fixture/lookuptable.php")
      #expect(request.url?.query == "l=4328&s=2026-2027")
      return (Data("{\"table\":null}".utf8), 200)
    }
    let result = try await empty.standings(providerLeagueID: "4328", season: "2026-2027", competitionID: "league", entities: [], now: now)
    #expect(result.status == "empty")
    #expect(result.updatedAt == now)
    #expect(!result.sourceURL.contains("fixture"))
    let bad = TheSportsDBAdapter(apiKey: "fixture") { _ in (Data("{\"table\":[{\"strTeam\":\"Missing Identity\"}]}".utf8), 200) }
    await #expect(throws: SportsProviderError.invalidResponse) {
      try await bad.standings(providerLeagueID: "4328", season: "2026-2027", competitionID: "league", entities: [], now: now)
    }
  }

  @Test func staleTablesAndOutagesRemainVisibleWithDegradation() {
    let snapshot = SportsStandingSnapshot(competitionID: "league", season: "2026", status: "available", updatedAt: now)
    #expect(!snapshot.served(at: now).degraded)
    #expect(snapshot.served(at: now.addingTimeInterval(3601)).degraded)
    #expect(snapshot.served(at: now, remoteFailed: true).degraded)
    #expect(snapshot.served(at: now, remoteFailed: true).status == "available")
  }
}
