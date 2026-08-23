import Testing
@testable import WireCore

@Suite("Wire regional edition ranker")
struct WireRegionalEditionRankerTests {
  private struct Story: Equatable {
    let id: String
    let topics: [String]
    let reasons: [WireReasonCode]
  }

  @Test("American politics moves down at most three positions")
  func boundedDownrank() {
    let stories = [
      Story(id: "politics", topics: ["US Politics"], reasons: [.freshPublication]),
      Story(id: "science", topics: ["science"], reasons: [.freshPublication]),
      Story(id: "culture", topics: ["culture"], reasons: [.freshPublication]),
      Story(id: "technology", topics: ["technology"], reasons: [.freshPublication]),
      Story(id: "health", topics: ["health"], reasons: [.freshPublication]),
    ]
    let adjusted = WireRegionalEditionRanker.downrankAmericanPolitics(
      in: stories, topicKeys: \.topics, reasons: \.reasons
    )
    #expect(adjusted.map(\.id) == ["science", "culture", "technology", "politics", "health"])
  }

  @Test("globally important reasons remain in canonical order")
  func importantStoriesAreExempt() {
    for reason in [
      WireReasonCode.breakingStory,
      .widelyDiscussed,
      .sharedAcrossCommunities,
    ] {
      #expect(!WireRegionalEditionRanker.shouldDownrank(
        topicKeys: ["american-politics"], reasons: [reason]
      ))
    }
  }

  @Test("classification requires explicit publisher-authored US politics tags")
  func conservativeTagClassification() {
    #expect(WireRegionalEditionRanker.shouldDownrank(
      topicKeys: ["United States", "Politics"], reasons: [.freshPublication]
    ))
    #expect(!WireRegionalEditionRanker.shouldDownrank(
      topicKeys: ["American Football"], reasons: [.freshPublication]
    ))
    #expect(!WireRegionalEditionRanker.shouldDownrank(
      topicKeys: ["French Politics"], reasons: [.freshPublication]
    ))
  }
}
