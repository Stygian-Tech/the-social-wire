import Foundation
import Testing
@testable import WireCore

@Suite("The Wire ranker")
struct WireRankerTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("is deterministic independent of input order")
  func deterministic() throws {
    let candidates = [candidate("b", actors: 20, signals1h: 6), candidate("a", actors: 20, signals1h: 6)]
    let first = try WireRanker.rank(candidates: candidates, asOf: now, config: .init())
    let second = try WireRanker.rank(candidates: Array(candidates.reversed()), asOf: now, config: .init())
    #expect(first == second)
    #expect(first.items.map(\.candidate.canonicalKey) == ["a", "b"])
  }

  @Test("filters candidates by age, quality, and signal floor")
  func eligibilityFilters() throws {
    var old = candidate("old", actors: 10)
    old.publishedAt = now.addingTimeInterval(-3_000_000)
    var lowQuality = candidate("quality", actors: 10)
    lowQuality.sourceConfidence = 0.1
    var quiet = candidate("quiet", actors: 0, recommendations: 0)
    quiet.representativeURI = "at://did:example:quiet/app.bsky.feed.post/1"
    let accepted = candidate("accepted", actors: 3)
    let result = try WireRanker.rank(
      candidates: [old, lowQuality, quiet, accepted], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["accepted"])
    #expect(result.diagnostics.rejectedForAge == 1)
    #expect(result.diagnostics.rejectedForQuality == 1)
    #expect(result.diagnostics.rejectedForSignalFloor == 1)
  }

  @Test("emits public reason codes without actor data")
  func reasonCodes() throws {
    var item = candidate("story", actors: 15, signals1h: 8, communities: 4)
    item.publishedAt = now.addingTimeInterval(-7_200)
    item.firstSeenAt = now.addingTimeInterval(-7_200)
    item.lastSignalAt = now.addingTimeInterval(-600)
    let result = try WireRanker.rank(candidates: [item], asOf: now, config: .init())
    #expect(result.items[0].reasonCodes.contains(.breakingStory))
    #expect(result.items[0].reasonCodes.contains(.widelyDiscussed))
    #expect(result.items[0].reasonCodes.count == 2)
  }

  @Test("recommendations can satisfy the admission floor")
  func recommendationsAdmit() throws {
    let result = try WireRanker.rank(
      candidates: [candidate("recommended", actors: 0, recommendations: 1)],
      asOf: now,
      config: .init()
    )
    #expect(result.items.count == 1)
  }

  @Test("trusted direct publications have a bounded fresh-content lane")
  func freshPublicationLane() throws {
    let result = try WireRanker.rank(
      candidates: [candidate("fresh", actors: 0, signals1h: 0, recommendations: 0)],
      asOf: now,
      config: .init()
    )
    #expect(result.items.count == 1)
    #expect(result.items[0].reasonCodes.contains(.freshPublication))
  }

  private func candidate(
    _ key: String,
    actors: Int,
    signals1h: Int = 2,
    communities: Int = 2,
    recommendations: Int = 0
  ) -> WireCandidate {
    WireCandidate(
      canonicalKey: key,
      canonicalURL: "https://\(key).example/story",
      representativeURI: "at://did:example:\(key)/site.standard.document/1",
      sourceDomain: "\(key).example",
      publicationID: "publication-\(key)",
      authorKey: "author-\(key)",
      topicKeys: ["technology"],
      publishedAt: now.addingTimeInterval(-3_600),
      firstSeenAt: now.addingTimeInterval(-3_600),
      lastSignalAt: now.addingTimeInterval(-60),
      distinctActors1h: max(0, actors / 2),
      distinctActors24h: actors,
      distinctActors7d: actors,
      signals1h: signals1h,
      signals24h: 16,
      signals7d: 20,
      communities24h: communities,
      recommendations24h: recommendations,
      sourceConfidence: 0.8
    )
  }
}
