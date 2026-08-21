import Foundation
import Testing
@testable import WireCore

@Suite("The Wire diversity reranker")
struct WireDiversityRerankerTests {
  @Test("defers repeated domains while preserving every candidate")
  func domainCap() {
    let ranked = [item("a", domain: "one.example"), item("b", domain: "one.example"), item("c", domain: "two.example")]
    let result = WireDiversityReranker.rerank(
      ranked,
      policy: .init(firstPageLimit: 2, maxPerDomain: 1, maxPerPublication: 10, maxPerAuthor: 10, maxPerTopic: 10)
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["a", "c", "b"])
    #expect(result.interventions == [.init(canonicalKey: "b", kind: .domain)])
  }

  @Test("relaxes caps when otherwise unable to fill the page")
  func fillsPage() {
    let ranked = [item("a", domain: "one.example"), item("b", domain: "one.example")]
    let result = WireDiversityReranker.rerank(
      ranked,
      policy: .init(firstPageLimit: 2, maxPerDomain: 1, maxPerPublication: 10, maxPerAuthor: 10, maxPerTopic: 10)
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["a", "b"])
    #expect(result.interventions.first == .init(canonicalKey: "b", kind: .domain))
    #expect(result.interventions.contains { $0.kind == .relaxation })
  }

  private func item(_ key: String, domain: String) -> WireScoredCandidate {
    .init(
      candidate: WireCandidate(
        canonicalKey: key,
        canonicalURL: "https://\(domain)/\(key)",
        representativeURI: "at://example/\(key)",
        sourceDomain: domain,
        publicationID: key,
        authorKey: key,
        topicKeys: [key],
        firstSeenAt: .distantPast
      ),
      score: 1,
      reasonCodes: []
    )
  }
}
