import Foundation
import SportsCore
import Testing

struct SportsCatalogGroupingTests {
  @Test func reviewedHierarchyPreservesIdentitiesAndReferences() throws {
    let entities = SportsReviewedCatalog.entities
    let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
    let feeds = SportsNamedFeeds.catalog(entities: entities)
    for team in entities.filter({ $0.kind == "ncaa-team" }) {
      #expect(team.groupPath?.first == "NCAA")
      #expect(team.groupPath?.contains(team.division ?? "") == true)
      #expect(team.competitionIDs.allSatisfy { byID[$0]?.kind == "competition" })
      #expect(feeds.first { $0.entityIDs == [team.id] }?.groupPath == team.groupPath)
    }
    let alabama = try #require(entities.first { $0.name == "Alabama Football" })
    #expect(alabama.id == SportsReviewedCatalog.id("ncaa-team:Alabama:ncaa-football"))
    let notreDameFootball = try #require(entities.first { $0.name == "Notre Dame Football" })
    let notreDameBasketball = try #require(entities.first { $0.name == "Notre Dame Women's Basketball" })
    #expect(notreDameFootball.groupPath?.last == "Independents")
    #expect(notreDameBasketball.groupPath?.last == "Atlantic Coast Conference")
    #expect(entities.filter { $0.kind == "ncaa-team" && $0.division == "Division II" }.count == 70)
    #expect(entities.filter { $0.kind == "ncaa-team" && $0.division == "Division III" }.count == 33)
    #expect(!entities.contains { $0.name == "Emory Football" })
    #expect(!entities.contains { $0.name == "Lake Superior State Football" })
    #expect(entities.first { $0.name == "New York Giants" }?.groupPath?.suffix(2) == ["NFC", "East"])
  }

  @Test func conferenceFeedsMatchOnlySportSpecificMembers() throws {
    let entities = SportsReviewedCatalog.entities
    let feeds = SportsNamedFeeds.catalog(entities: entities)
    let gliac = try #require(feeds.first { $0.title == "Great Lakes Intercollegiate Athletic Conference Football" })
    let miaa = try #require(feeds.first { $0.title == "Mid-America Intercollegiate Athletics Association Football" })
    let football = SportsResolver.analyze(title: "Grand Valley State football wins championship game", summary: nil, catalog: entities)
    let basketball = SportsResolver.analyze(title: "Grand Valley State women's basketball wins championship game", summary: nil, catalog: entities)
    #expect(gliac.matches(football))
    #expect(!miaa.matches(football))
    #expect(!gliac.matches(basketball))
    let team = try #require(entities.first { $0.name == "Grand Valley State Football" })
    let candidate = SportsRankCandidate(item: SportsCoreTests().item("gliac"), analysis: football, baseScore: 1)
    let conference = try #require(gliac.entityIDs.first)
    #expect(SportsRanker.rank(candidates: [candidate], muteIDs: [conference], entities: entities).isEmpty)
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [team.id], muteIDs: [conference], entities: entities).count == 1)
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [team.id], muteIDs: [conference, team.id], entities: entities).isEmpty)
    let carnegieFootball = try #require(entities.first { $0.name == "Carnegie Mellon Football" })
    let carnegieBasketball = try #require(entities.first { $0.name == "Carnegie Mellon Men's Basketball" })
    #expect(carnegieFootball.groupPath?.last == "Centennial Conference")
    #expect(carnegieBasketball.groupPath?.last == "University Athletic Association")
  }

  @Test func groupingRevisionAndLegacyDecoding() throws {
    let old = Data(#"{"id":"x","title":"Legacy","kind":"team","entityIDs":[],"description":"Legacy"}"#.utf8)
    #expect(try JSONDecoder().decode(SportsFeedDefinition.self, from: old).groupPath == nil)
    let one = SportsEntity(id: "x", name: "X", kind: "team", groupPath: ["Teams", "Old"])
    let two = SportsEntity(id: "x", name: "X", kind: "team", groupPath: ["Teams", "New"])
    #expect(try SportsCatalogSnapshot.revision(entities: [one]) != SportsCatalogSnapshot.revision(entities: [two]))
    #expect(SportsReviewedCatalog.entities.allSatisfy { ($0.groupPath?.count ?? 0) <= 8 })
  }
}
