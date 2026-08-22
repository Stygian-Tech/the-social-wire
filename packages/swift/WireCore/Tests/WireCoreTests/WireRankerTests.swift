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
    let accepted = candidate("accepted", actors: 5)
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
      candidates: [candidate("recommended", actors: 0, recommendations: 2)],
      asOf: now,
      config: .init()
    )
    #expect(result.items.count == 1)
  }

  @Test("trusted direct publications have a bounded fresh-content lane")
  func freshPublicationLane() throws {
    let result = try WireRanker.rank(
      candidates: [
        candidate("fresh", actors: 3, signals1h: 0, recommendations: 0, standardSite: true)
      ],
      asOf: now,
      config: .init()
    )
    #expect(result.items.count == 1)
    #expect(result.items[0].reasonCodes.contains(.freshPublication))
  }

  @Test("passive engagement cannot satisfy the conversation gate")
  func passiveEngagementDoesNotAdmit() throws {
    var passive = candidate("passive", actors: 20)
    passive.shares24h = 0
    passive.recommendations24h = 0
    passive.distinctLikes24h = 20
    passive.distinctReposts24h = 20
    let result = try WireRanker.rank(candidates: [passive], asOf: now, config: .init())
    #expect(result.items.isEmpty)
    #expect(result.diagnostics.rejectedForSignalFloor == 1)
  }

  @Test("Standard Site still requires high-intent conversation")
  func standardSiteRequiresConversation() throws {
    let quiet = candidate("quiet-standard", actors: 2, standardSite: true)
    let discussed = candidate("discussed-standard", actors: 3, standardSite: true)
    let result = try WireRanker.rank(
      candidates: [quiet, discussed], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["discussed-standard"])
  }

  @Test("bounded source quality signals break otherwise equal ranking ties")
  func sourceQualitySignals() throws {
    let plain = candidate("a-plain", actors: 8)
    let openGraph = candidate("b-open-graph", actors: 8, openGraph: true)
    let standard = candidate("c-standard", actors: 8, standardSite: true)
    let result = try WireRanker.rank(
      candidates: [plain, openGraph, standard], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == [
      "c-standard", "b-open-graph", "a-plain",
    ])
  }

  @Test("quality backfill fills a sparse edition before general backfill")
  func qualityBackfill() throws {
    let quality = candidate("quality", actors: 3, openGraph: true)
    let general = candidate("general", actors: 3)
    let result = try WireRanker.rank(
      candidates: [general, quality], asOf: now, config: .init(minimumRankedItems: 1)
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["quality"])
    #expect(result.diagnostics.qualityBackfillCount == 1)
    #expect(result.diagnostics.generalBackfillCount == 0)
  }

  private func candidate(
    _ key: String,
    actors: Int,
    signals1h: Int = 2,
    communities: Int = 2,
    recommendations: Int = 0,
    standardSite: Bool = false,
    openGraph: Bool = false
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
      shares1h: signals1h,
      shares24h: actors,
      sourceConfidence: 0.8,
      isStandardSite: standardSite,
      hasUsableOpenGraphMetadata: openGraph
    )
  }
}
