import Foundation
import SportsCore
import Testing
@testable import WireWorkerCore

struct SportsCatalogRefreshPolicyTests {
  @Test func newReviewedManifestBypassesDailyTTL() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let previous = SportsCatalogSnapshot(version: "sports-reviewed-v4:previous", generatedAt: now.addingTimeInterval(-60), entities: [])
    #expect(SportsReviewedCatalog.version == "sports-reviewed-v12")
    #expect(SportsCatalogRefreshPolicy.shouldRefresh(previous, asOf: now))
    let current = SportsCatalogSnapshot(version: SportsReviewedCatalog.version + ":current", generatedAt: now.addingTimeInterval(-60), entities: SportsReviewedCatalog.entities)
    #expect(!SportsCatalogRefreshPolicy.shouldRefresh(current, asOf: now))
    let prefixCollision = SportsCatalogSnapshot(version: SportsReviewedCatalog.version + "0:future", generatedAt: now, entities: [])
    #expect(SportsCatalogRefreshPolicy.shouldRefresh(prefixCollision, asOf: now))
    #expect(SportsCatalogRefreshPolicy.shouldRefresh(current, asOf: current.generatedAt.addingTimeInterval(86400)))
  }
  @Test func sameVersionProviderSnapshotCannotMaskMissingOrChangedReviewedHierarchy() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reviewed = SportsReviewedCatalog.entities
    let hockey = SportsReviewedCatalog.id("sport:hockey")
    let missing = SportsCatalogSnapshot(version: SportsReviewedCatalog.version + ":provider", generatedAt: now,
      entities: reviewed.filter { $0.id != hockey })
    #expect(SportsCatalogRefreshPolicy.shouldRefresh(missing, asOf: now))
    let changed = reviewed.map { entity in
      entity.id == SportsReviewedCatalog.id("sport:ice-hockey")
        ? SportsEntity(id: entity.id, name: entity.name, kind: entity.kind, aliases: entity.aliases, groupPath: ["Sports"])
        : entity
    }
    #expect(SportsCatalogRefreshPolicy.shouldRefresh(.init(version: SportsReviewedCatalog.version + ":old-path", generatedAt: now, entities: changed), asOf: now))
    let enriched = reviewed.map { entity in
      SportsEntity(id: entity.id, name: entity.name, kind: entity.kind, sportID: entity.sportID,
        competitionIDs: entity.competitionIDs, aliases: entity.aliases + ["Provider Alias"], providerIDs: ["thesportsdb": "123"],
        active: false, schoolID: entity.schoolID, gender: entity.gender, division: entity.division, groupPath: entity.groupPath)
    }
    #expect(!SportsCatalogRefreshPolicy.shouldRefresh(.init(version: SportsReviewedCatalog.version + ":enriched", generatedAt: now, entities: enriched), asOf: now))
  }

  @Test func reviewedRefreshRetainsProviderIdentityAndReviewedGrouping() {
    let definition = SportsEntity(id: "team", name: "New Name", kind: "team", aliases: ["RBR"], groupPath: ["Teams", "Motorsport", "Formula 1"])
    let existing = SportsEntity(id: "team", name: "Old Name", kind: "team", competitionIDs: ["competition"], aliases: ["Legacy"], providerIDs: ["thesportsdb": "1"], groupPath: ["Old Group"], abbreviation: "ABC")
    let result = SportsReviewedCatalogMerge.definition(definition, existing: existing)
    #expect(result.id == existing.id)
    #expect(result.providerIDs == existing.providerIDs)
    #expect(result.abbreviation == existing.abbreviation)
    #expect(result.competitionIDs == existing.competitionIDs)
    #expect(result.groupPath == definition.groupPath)
    #expect(Set(result.aliases) == ["RBR", "Legacy"])
  }
}
