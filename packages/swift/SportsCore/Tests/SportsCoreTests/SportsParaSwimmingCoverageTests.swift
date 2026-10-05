import Foundation
import SportsCore
import Testing

struct SportsParaSwimmingCoverageTests {
  @Test func distinctClassesAndMedleyIndicesAreSelectable() throws {
    let catalog = SportsReviewedCatalog.entities
    let classes = catalog.filter { $0.kind == "classification" }
    #expect(classes.count == 41)
    #expect(Set(classes.map(\.id)).count == 41)
    #expect(!classes.contains { $0.name == "Para Swimming SB10" })
    for prefix in ["S", "SB", "SM"] {
      let id = SportsReviewedCatalog.id("classification:para-swimming-" + prefix.lowercased() + "8")
      let entity = try #require(classes.first { $0.id == id })
      #expect(entity.groupPath?.contains("Classes and Medley Indices") == true)
      #expect(SportsNamedFeeds.catalog(entities: catalog).contains { $0.entityIDs == [id] })
    }
  }
  @Test func exactClassCodesMatchBroadParaWithoutInferringParalympics() throws {
    let catalog = SportsReviewedCatalog.entities
    for code in ["S1", "S8", "S10", "S14", "SB1", "SB9", "SB11", "SB14", "SM1", "SM10", "SM14"] {
      let id = SportsReviewedCatalog.id("classification:para-swimming-" + code.lowercased())
      let analysis = SportsResolver.analyze(title: "World Para Swimming Championships: \(code) gold medal race sets record", summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      let matchedIDs = Set(analysis.associations.map(\.entityID))
      #expect(catalog.filter { $0.kind == "classification" && matchedIDs.contains($0.id) }.map(\.id) == [id])
      #expect(analysis.competitionIDs.contains(SportsReviewedCatalog.id("competition:para-swimming")))
      #expect(!analysis.competitionIDs.contains(SportsReviewedCatalog.id("competition:paralympic-swimming")))
      let feed = try #require(SportsNamedFeeds.catalog(entities: catalog).first { $0.entityIDs == [id] })
      #expect(feed.matches(analysis))
    }
  }
  @Test func ambiguousCodesAndUnstatedClassificationNeverInferAClass() {
    let catalog = SportsReviewedCatalog.entities
    let classes = Set(catalog.filter { $0.kind == "classification" }.map(\.id))
    for title in ["Samsung S8 wins phone design championship", "Audi S8 race wins championship", "S8 cycling race at Paralympics", "Swimming championships S8 sponsor unveils phone", "Para swimming SB10 gold medal race", "Para swimming S80 gold medal race", "Para swimming S 8 gold medal race", "Blind swimmer wins Paralympic gold medal", "Jessica Long wins para swimming world championship"] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(!analysis.associations.contains { classes.contains($0.entityID) })
    }
  }
  @Test func paralympicStrokeReportingKeepsPrefixesDistinct() {
    let analysis = SportsResolver.analyze(title: "Paralympic 100m freestyle S8 race ends in record", summary: nil, catalog: SportsReviewedCatalog.entities)
    #expect(analysis.associations.contains { $0.entityID == SportsReviewedCatalog.id("classification:para-swimming-s8") && $0.confidence >= 0.9 })
    #expect(!analysis.associations.contains { $0.entityID == SportsReviewedCatalog.id("classification:para-swimming-sb8") })
    #expect(!analysis.associations.contains { $0.entityID == SportsReviewedCatalog.id("classification:para-swimming-sm8") })
  }
  @Test func classificationFollowUsesBroadBoostAndMuteWins() {
    let catalog = SportsReviewedCatalog.entities
    let classID = SportsReviewedCatalog.id("classification:para-swimming-s8")
    let analysis = SportsResolver.analyze(title: "Para swimming S8 race record", summary: nil, catalog: catalog)
    let item = SportsCoreTests().item("class-story")
    let candidate = SportsRankCandidate(item: item, analysis: analysis, baseScore: 1)
    let competitor = SportsRankCandidate(item: SportsCoreTests().item("competitor"),
      analysis: .init(eligible: true, materiality: analysis.materiality, associations: []), baseScore: 1.05)
    #expect(SportsRanker.rank(candidates: [candidate, competitor], followIDs: [classID], entities: catalog, reserveGlobal: false).first?.item.itemID == "class-story")
    let stronger = SportsRankCandidate(item: SportsCoreTests().item("stronger"),
      analysis: competitor.analysis, baseScore: 1.15)
    #expect(SportsRanker.rank(candidates: [candidate, stronger], followIDs: [classID], entities: catalog, reserveGlobal: false).first?.item.itemID == "stronger")
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [classID], muteIDs: [classID], entities: catalog).isEmpty)
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [classID], muteIDs: [SportsReviewedCatalog.id("competition:para-swimming")], entities: catalog).isEmpty)
  }

  @Test func boundedPriorGenerationReanalysisTiming() {
    let index = SportsEntityIndex(entities: SportsReviewedCatalog.entities)
    let started = Date()
    var eligible = 0
    for number in 0..<3000 {
      let title = number % 2 == 0 ? "NBA championship reporting fixture \(number)" : "Para swimming S8 race record fixture \(number)"
      if SportsResolver.analyze(title: title, summary: nil, index: index).eligible { eligible += 1 }
    }
    #expect(eligible == 3000)
    print("Sports bounded 3000-candidate reanalysis: \(Date().timeIntervalSince(started)) seconds")
  }

}
