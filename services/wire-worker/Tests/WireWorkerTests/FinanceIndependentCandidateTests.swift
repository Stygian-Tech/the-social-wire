import FinanceCore
import Foundation
import Testing
import WireCore
@testable import WireWorkerCore

struct FinanceIndependentCandidateTests {
  @Test("Finance quality scoring admits source-validated macro reporting without relaxing general Wire admission")
  func independentTopicAdmission() throws {
    let now = Date()
    let candidate = WireCandidate(canonicalKey: "macro", canonicalURL: "https://example.com/macro", representativeURI: nil,
      sourceDomain: "example.com", publishedAt: now, firstSeenAt: now, sourceConfidence: 0.9,
      isStandardSite: true, hasUsableThumbnail: true)
    #expect(try WireRanker.rank(candidates: [candidate], asOf: now, config: .init()).items.isEmpty)
    #expect(try WireRanker.rank(candidates: [candidate], asOf: now, config: FinanceCandidateQuality.ranking).items.count == 1)
    let unknown = WireCandidate(canonicalKey: "unknown", canonicalURL: "https://example.com/unknown", representativeURI: nil,
      sourceDomain: "example.com", firstSeenAt: now, sourceConfidence: 0.2, isStandardSite: true)
    #expect(try WireRanker.rank(candidates: [unknown], asOf: now, config: FinanceCandidateQuality.ranking).items.isEmpty)
    #expect(FinanceResolver.analyze(title: "Central bank changes interest rates following inflation report", summary: nil, catalog: []).eligible)
    #expect(FinanceResolver.analyze(title: "Healthcare sector faces pharmaceutical supply reforms", summary: nil, catalog: []).eligible)
    #expect(!FinanceResolver.analyze(title: "Local football club wins its championship match", summary: nil, catalog: []).eligible)
  }
}
