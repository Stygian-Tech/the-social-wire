import Foundation
import Testing
import SportsCore

struct SportsHockeyScopeTests {
  private let catalog = SportsReviewedCatalog.entities
  private func id(_ key: String) -> String { SportsReviewedCatalog.id(key) }

  @Test func branchEvidenceDoesNotTurnGenericOrFieldHockeyIntoIceHockey() {
    let generic = SportsResolver.analyze(title: "Hockey championship begins this weekend", summary: nil, catalog: catalog)
    #expect(generic.sportIDs.contains(id("sport:hockey")))
    #expect(!generic.sportIDs.contains(id("sport:ice-hockey")))
    let field = SportsResolver.analyze(title: "Field hockey championship sees late winning goal", summary: nil, catalog: catalog)
    #expect(field.sportIDs.contains(id("sport:field-hockey")))
    #expect(field.sportIDs.contains(id("sport:hockey")))
    #expect(!field.sportIDs.contains(id("sport:ice-hockey")))
    let ice = SportsResolver.analyze(title: "NHL Stanley Cup playoff game decided in overtime", summary: nil, catalog: catalog)
    #expect(ice.sportIDs.contains(id("sport:ice-hockey")))
    #expect(ice.sportIDs.contains(id("sport:hockey")))
    #expect(!ice.sportIDs.contains(id("sport:field-hockey")))
  }
  @Test func umbrellaMatchesDescendantsAndMuteRequiresDirectPersonalException() {
    let umbrella = id("sport:hockey"), field = id("sport:field-hockey")
    let analysis = SportsResolver.analyze(title: "Field hockey championship starts", summary: nil, catalog: catalog)
    let definition = SportsFeedDefinition(id: "entity:" + umbrella, title: "Hockey", kind: "sport", entityIDs: [umbrella], description: "")
    #expect(definition.matches(analysis))
    let candidate = SportsRankCandidate(item: SportsCoreTests().item("field"), analysis: analysis, baseScore: 1)
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [field], muteIDs: [umbrella], entities: catalog).isEmpty)
    let team = SportsEntity(id: "fixture-team", name: "Reviewed Field Team", kind: "team", sportID: field)
    let personalAnalysis = SportsArticleAnalysis(eligible: true, materiality: "reporting", associations: [.init(entityID: team.id, confidence: 0.94, evidence: ["verified"], prominence: 0)], sportIDs: [field])
    let personal = SportsRankCandidate(item: SportsCoreTests().item("team"), analysis: personalAnalysis, baseScore: 1)
    #expect(SportsRanker.rank(candidates: [personal], followIDs: [team.id], muteIDs: [umbrella], entities: catalog + [team]).count == 1)
    #expect(SportsRanker.rank(candidates: [personal], followIDs: [team.id], muteIDs: [umbrella, team.id], entities: catalog + [team]).isEmpty)
  }
  @Test func umbrellaSchedulesAndStandingsExpandDownWithoutSiblingLeak() {
    let umbrella = id("sport:hockey"), field = id("sport:field-hockey"), ice = id("sport:ice-hockey")
    let iceLeague = SportsEntity(id: "ice-league", name: "Ice League", kind: "competition", sportID: ice)
    let fieldLeague = SportsEntity(id: "field-league", name: "Field League", kind: "competition", sportID: field)
    let entities = catalog + [iceLeague, fieldLeague]
    let all = SportsInterestCompetitionScope.competitionIDs(preferredIDs: [umbrella], catalog: entities, now: Date())
    #expect(all.contains(iceLeague.id)); #expect(all.contains(fieldLeague.id))
    let fieldOnly = SportsInterestCompetitionScope.competitionIDs(preferredIDs: [field], catalog: entities, now: Date())
    #expect(fieldOnly.contains(fieldLeague.id)); #expect(!fieldOnly.contains(iceLeague.id))
    let event = SportsEvent(id: "event", competitionID: fieldLeague.id, title: "Match", startsAt: Date(), status: "scheduled", updatedAt: Date())
    #expect(SportsEventOrdering.interestTier(event, preferredIDs: [umbrella], catalog: entities) == 2)
    #expect(SportsEventOrdering.interestTier(event, preferredIDs: [ice], catalog: entities) == 3)
  }
  @Test func broadCatalogRankingDoesNotRebuildHierarchyPerComparison() {
    let field = id("sport:field-hockey"), umbrella = id("sport:hockey")
    let analysis = SportsArticleAnalysis(eligible: true, materiality: "reporting", associations: [], sportIDs: [field])
    let fixture = SportsCoreTests()
    let candidates = (0..<3000).map { ordinal in
      SportsRankCandidate(item: fixture.item("story-\(ordinal)", title: "Story \(ordinal)"), analysis: analysis, baseScore: Double(3000 - ordinal))
    }
    let started = Date()
    let ranked = SportsRanker.rank(candidates: candidates, followIDs: [umbrella], entities: catalog, reserveGlobal: false)
    #expect(ranked.count == 3000)
    #expect(ranked.first?.item.itemID == "story-0")
    #expect(Date().timeIntervalSince(started) < 5)
  }
  @Test func duplicateStoryIDsKeepTheHigherScoreAndItsEvidence() {
    let field = id("sport:field-hockey"), ice = id("sport:ice-hockey")
    let item = SportsCoreTests().item("duplicate", title: "Same story")
    let low = SportsRankCandidate(item: item, analysis: .init(eligible: true, materiality: "reporting", associations: [], sportIDs: [ice]), baseScore: 1)
    let high = SportsRankCandidate(item: item, analysis: .init(eligible: true, materiality: "reporting", associations: [], sportIDs: [field]), baseScore: 2)
    let ranked = SportsRanker.rank(candidates: [low, high], entities: catalog, reserveGlobal: false)
    #expect(ranked.count == 1)
    #expect(ranked.first?.baseScore == 2)
    #expect(ranked.first?.analysis.sportIDs == [field])
  }
}
