import Foundation
import Testing
@testable import WireCore

@Suite("Your Circle Corpus candidates")
struct WireCorpusCandidateTests {
  @Test("only sharing and curation actions are eligible for named attribution", arguments: [
    (WireSignalKind.recommendation, true),
    (.share, true),
    (.quote, true),
    (.repost, true),
    (.reply, false),
    (.like, false),
    (.publication, false),
  ])
  func attributionEligibility(kind: WireSignalKind, expected: Bool) {
    let fact = WireCorpusSignalFact(
      actorHash: String(repeating: "a", count: 64),
      kind: kind,
      sourceCollection: "app.bsky.feed.post",
      sourceAction: kind.rawValue,
      sourceURI: "at://did:plc:example/app.bsky.feed.post/1",
      occurredAt: Date(timeIntervalSince1970: 100)
    )
    #expect(fact.isNamedAttributionEligible == expected)
  }

  @Test("candidate request bounds are explicit")
  func requestBounds() {
    #expect(WireCorpusCandidateRequest.maximumActorHashesPerRequest == 5_000)
    #expect(WireCorpusCandidateRequest.maximumStoriesPerRequest == 500)
  }
}
