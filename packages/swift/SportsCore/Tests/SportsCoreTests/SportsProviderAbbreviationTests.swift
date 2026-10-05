import Foundation
import Testing
@testable import SportsCore

@Suite("Explicit Provider Team Abbreviations")
struct SportsProviderAbbreviationTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func importsOnlyTheExplicitCodeAndKeepsIdentityThroughRename() throws {
    let league = SportsEntity(id: "league", name: "Fixture League", kind: "competition", sportID: "sport")
    let first = try #require(SportsReferenceImport.team(record: ["idTeam": "123", "strTeam": "Old Team", "strTeamShort": " abc "], competition: league, existing: [], now: now))
    #expect(first.abbreviation == "ABC")
    let renamed = try #require(SportsReferenceImport.team(record: ["idTeam": "123", "strTeam": "New Team"], competition: league, existing: [first], now: now.addingTimeInterval(1)))
    #expect(renamed.id == first.id)
    #expect(renamed.abbreviation == first.abbreviation)
    #expect(renamed.aliases.contains(first.name))
    let changedProvider = try #require(SportsReferenceImport.team(record: ["idTeam": "789", "strTeam": first.name], competition: league, existing: [first], now: now))
    #expect(changedProvider.abbreviation == nil)
    let withoutCode = try #require(SportsReferenceImport.team(record: ["idTeam": "456", "strTeam": "Different Team", "strAlternate": "DIF"], competition: league, existing: [], now: now))
    #expect(withoutCode.abbreviation == nil)
    var unchangedIdentity = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    unchangedIdentity.removeValue(forKey: "abbreviation")
    let sameTeamWithoutCode = try JSONDecoder().decode(SportsEntity.self, from: JSONSerialization.data(withJSONObject: unchangedIdentity))
    #expect(sameTeamWithoutCode.id == first.id)
    #expect(try SportsCatalogSnapshot.revision(entities: [first]) != SportsCatalogSnapshot.revision(entities: [sameTeamWithoutCode]))
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(SportsEntity.self, from: encoder.encode(first)) == first)
  }

  @Test func rejectsUnverifiedIdsAndUnsafeOrNonCodeValues() {
    for value in ["A", "TOOLONGCODE", "Man Utd", "<b>ABC</b>", "ÅBC", "A/B"] {
      #expect(SportsProviderAbbreviation.validated(value, providerTeamID: "123") == nil)
    }
    #expect(SportsProviderAbbreviation.validated("ABC", providerTeamID: "unverified") == nil)
    #expect(SportsProviderAbbreviation.validated("ABC", providerTeamID: nil) == nil)
    #expect(SportsProviderAbbreviation.validated("U23", providerTeamID: "123") == "U23")
  }

  @Test func resolvesCodesOnlyInUniqueTeamContextAndFailsClosedOnCollisions() {
    let one = SportsEntity(id: "one", name: "One Team", kind: "team", competitionIDs: ["league"], providerIDs: ["thesportsdb": "1"], abbreviation: "ABC")
    let two = SportsEntity(id: "two", name: "Two Team", kind: "team", competitionIDs: ["league"], providerIDs: ["thesportsdb": "2"], abbreviation: "ABC")
    let otherLeague = SportsEntity(id: "three", name: "Three Team", kind: "team", competitionIDs: ["other"], providerIDs: ["thesportsdb": "3"], abbreviation: "ABC")
    let identity = SportsEventTeamIdentity(catalog: [one, two, otherLeague], now: now)
    func event(_ name: String, league: String) -> SportsEvent { .init(id: name, competitionID: league, title: name, startsAt: now, status: "scheduled", homeName: name, updatedAt: now) }
    #expect(identity.hydrate(event(one.name, league: "league")).homeAbbreviation == nil)
    #expect(identity.hydrate(event(two.name, league: "league")).homeAbbreviation == nil)
    #expect(identity.hydrate(event(otherLeague.name, league: "other")).homeAbbreviation == "ABC")
    #expect(identity.hydrate(event(otherLeague.name, league: "league")).homeAbbreviation == nil)
    let unique = SportsEventTeamIdentity(catalog: [one], now: now).hydrate(event(one.name, league: "league"))
    #expect(unique.homeAbbreviation == "ABC")
    #expect(unique.entityIDs == [one.id])
  }

  @Test func reviewedCanonicalCodeWinsOverProviderCode() {
    let id = SportsReviewedCatalog.id("team:nfl:Philadelphia Eagles")
    let team = SportsEntity(id: id, name: "Philadelphia Eagles", kind: "team", competitionIDs: ["nfl"], providerIDs: ["thesportsdb": "134936"], abbreviation: "EAG")
    let event = SportsEvent(id: "fixture", competitionID: "nfl", title: "Fixture", startsAt: now, status: "scheduled", homeName: team.name, updatedAt: now)
    #expect(SportsEventTeamIdentity(catalog: [team], now: now).hydrate(event).homeAbbreviation == SportsTeamAbbreviations.abbreviation(entityID: id))
    #expect(SportsTeamAbbreviations.abbreviation(entityID: id) != nil)
  }
}
