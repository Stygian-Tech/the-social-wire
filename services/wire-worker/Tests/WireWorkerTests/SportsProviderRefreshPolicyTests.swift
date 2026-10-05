import Foundation
import Testing
@testable import WireWorkerCore

struct SportsProviderRefreshPolicyTests {
  @Test func payloadCutoverBypassesOldClaimsOnceThenHonorsSharedCadence() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    for resource in ["events", "standings", "reference"] {
      let season = resource == "standings" ? "2026-2027" : nil
      let legacy = resource + ":competition" + (season.map { ":" + $0 } ?? "")
      let key = SportsProviderRefreshPolicy.key(resource, competitionID: "competition", season: season)
      var requested = [legacy: now]
      if resource == "reference" { requested[legacy + ":v2"] = now }
      #expect(SportsProviderRefreshPolicy.isDue(key: key, interval: 3600, requested: requested, asOf: now))
      requested[key] = now
      #expect(!SportsProviderRefreshPolicy.isDue(key: key, interval: 3600, requested: requested, asOf: now.addingTimeInterval(3599)))
      #expect(SportsProviderRefreshPolicy.isDue(key: key, interval: 3600, requested: requested, asOf: now.addingTimeInterval(3600)))
      #expect(requested[legacy] == now)
      #expect(key.hasPrefix(resource + ":"))
    }
  }
  @Test func failedReferenceRetriesAfterFiveMinutesRatherThanDaily() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let key = SportsProviderRefreshPolicy.key("reference", competitionID: "competition")
    let requested = [key: SportsProviderRefreshPolicy.failedClaim(asOf: now, interval: 86400)]
    #expect(!SportsProviderRefreshPolicy.isDue(key: key, interval: 86400, requested: requested, asOf: now.addingTimeInterval(299)))
    #expect(SportsProviderRefreshPolicy.isDue(key: key, interval: 86400, requested: requested, asOf: now.addingTimeInterval(300)))
    #expect(!SportsProviderRefreshPolicy.isDue(key: key, interval: 86400, requested: [key: now], asOf: now.addingTimeInterval(300)))
    #expect(SportsProviderRefreshPolicy.failureMetadata(URLError(.timedOut))["category"] == "provider-transport")
  }
  @Test func rosterAndFullScheduleClaimsKeepExistingCadence() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    for resource in ["roster", "schedule"] {
      let season = resource == "schedule" ? "2026-2027" : nil
      let key = SportsProviderRefreshPolicy.key(resource, competitionID: "competition", season: season)
      let legacy = resource + ":competition" + (season.map { ":" + $0 } ?? "")
      #expect(key == legacy)
      #expect(!SportsProviderRefreshPolicy.isDue(key: key, interval: 3600, requested: [legacy: now], asOf: now))
    }
  }
}
