import Foundation
import Testing
@testable import SportsCore

struct SportsWinterHierarchyTests {
  @Test("Ice Hockey belongs to both Hockey and Winter Sports without changing its picker parent")
  func reviewedWinterContainment() {
    let catalog = SportsReviewedCatalog.entities
    let ice = SportsReviewedCatalog.id("sport:ice-hockey")
    let hockey = SportsReviewedCatalog.id("sport:hockey")
    let winter = SportsReviewedCatalog.id("sport:winter-sports")
    let field = SportsReviewedCatalog.id("sport:field-hockey")
    let winterChildren = SportsSportHierarchy.descendants(of: [winter], catalog: catalog)
    #expect(winterChildren.contains(ice))
    #expect(!winterChildren.contains(field))
    #expect(SportsSportHierarchy.ancestors(of: [ice], catalog: catalog).isSuperset(of: [hockey, winter]))
    #expect(SportsSportHierarchy.ancestors(of: [field], catalog: catalog).contains(winter) == false)
    #expect(catalog.first { $0.id == ice }?.sportID == hockey)
    #expect(SportsInterestCompetitionScope.competitionIDs(preferredIDs: [winter], catalog: catalog, now: Date()).contains(SportsReviewedCatalog.id("competition:nhl")))
  }
}
