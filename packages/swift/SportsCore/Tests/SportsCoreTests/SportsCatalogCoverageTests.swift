import Foundation
import SportsCore
import Testing

struct SportsCatalogCoverageTests {
  @Test func expandedCatalogRemainsIndexedAndUnambiguous() throws {
    let catalog = SportsReviewedCatalog.entities
    let index = SportsEntityIndex(entities: catalog)
    #expect(catalog.count > 800)
    #expect(Set(catalog.map(\.id)).count == catalog.count)
    let ambiguous = SportsResolver.analyze(title: "University of Chicago announces faculty appointments", summary: nil, index: index)
    #expect(!ambiguous.eligible)
    let wayneCollege = try #require(catalog.first { $0.name == "Wayne State College Football" })
    let wayneUniversity = try #require(catalog.first { $0.name == "Wayne State University Football" })
    #expect(wayneCollege.id != wayneUniversity.id)
    #expect(wayneCollege.competitionIDs != wayneUniversity.competitionIDs)
    let start = Date()
    for _ in 0..<100 {
      let analysis = SportsResolver.analyze(title: "Mount Union football advances in NCAA championship playoffs", summary: nil, index: index)
      #expect(analysis.eligible)
    }
    print("Sports reviewed coverage: \(catalog.count) entities; \(SportsNamedFeeds.catalog(entities: catalog).count) feeds; 100 indexed analyses \(Date().timeIntervalSince(start))s")
  }
}
