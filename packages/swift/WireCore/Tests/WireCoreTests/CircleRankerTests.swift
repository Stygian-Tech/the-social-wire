import Foundation
import Testing

@testable import WireCore

@Suite("Your Circle ranker")
struct CircleRankerTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("uses the locked five-component weighting")
  func fixedWeights() {
    let weights = CircleRankingWeights.standard
    #expect(weights.participantBreadth == 0.35)
    #expect(weights.relationshipStrength == 0.25)
    #expect(weights.recencyVelocity == 0.20)
    #expect(weights.qualityPresentation == 0.10)
    #expect(weights.interestMatch == 0.10)
    #expect(
      weights.participantBreadth + weights.relationshipStrength + weights.recencyVelocity
        + weights.qualityPresentation + weights.interestMatch == 1
    )
  }

  @Test("direct and multi-path one-hop relationships have bounded weights")
  func relationshipWeights() {
    #expect(CircleRelationship.direct.weight == 1)
    #expect(CircleRelationship.oneHop(pathCount: 1).weight == 0.5)
    #expect(CircleRelationship.oneHop(pathCount: 2).weight == 0.6)
    #expect(CircleRelationship.oneHop(pathCount: 3).weight == 0.7)
    #expect(CircleRelationship.oneHop(pathCount: 4).weight == 0.8)
    #expect(CircleRelationship.oneHop(pathCount: 20).weight == 0.8)
  }

  @Test("interest cannot establish graph eligibility")
  func interestsDoNotAdmit() throws {
    let interested = candidate("interested", signals: [], interest: 1)
    let result = try CircleRanker.rank(candidates: [interested], asOf: now)
    #expect(result.items.isEmpty)
    #expect(result.diagnostics.rejectedWithoutEligibleParticipants == 1)
  }

  @Test("only evidence in the seven-day window establishes eligibility")
  func evidenceWindow() throws {
    let expired = candidate(
      "expired",
      signals: [signal("actor", relationship: .direct, age: 7 * 24 * 60 * 60 + 1)]
    )
    let current = candidate(
      "current",
      signals: [signal("actor", relationship: .direct, age: 7 * 24 * 60 * 60)]
    )
    let result = try CircleRanker.rank(candidates: [expired, current], asOf: now)
    #expect(result.items.map(\.candidate.canonicalKey) == ["current"])
    #expect(result.diagnostics.rejectedWithoutEligibleParticipants == 1)
  }

  @Test("is deterministic independent of input and evidence order")
  func deterministic() throws {
    let signals = [
      signal("actor-b", relationship: .oneHop(pathCount: 2), age: 300),
      signal("actor-a", relationship: .direct, age: 600),
    ]
    let firstCandidates = [
      candidate("b", signals: signals),
      candidate("a", signals: Array(signals.reversed())),
    ]
    let first = try CircleRanker.rank(candidates: firstCandidates, asOf: now)
    let second = try CircleRanker.rank(
      candidates: Array(firstCandidates.reversed()), asOf: now
    )
    #expect(first == second)
    #expect(first.items.map(\.candidate.canonicalKey) == ["a", "b"])
  }

  @Test("deduplicates participants and retains their strongest relationship")
  func participantDeduplication() throws {
    let result = try CircleRanker.rank(
      candidates: [
        candidate(
          "story",
          signals: [
            signal("same", relationship: .oneHop(pathCount: 1), age: 3_600),
            signal("same", relationship: .direct, age: 60),
          ]
        )
      ],
      asOf: now
    )
    let item = try #require(result.items.first)
    #expect(item.components.relationshipStrength == 1)
    #expect(
      abs(
        item.components.participantBreadth
          - (log1p(1) / log1p(Double(CircleRankingConfig().participantBreadthTarget)))
      ) < 0.000_001
    )
  }

  @Test("component scores combine into the exact weighted total")
  func weightedTotal() throws {
    let signals = (0..<8).map {
      signal("direct-\($0)", relationship: .direct, age: 0)
    }
    let result = try CircleRanker.rank(
      candidates: [
        candidate("complete", signals: signals, quality: 1, presentation: 1, interest: 1)
      ],
      asOf: now
    )
    let item = try #require(result.items.first)
    #expect(item.components.participantBreadth == 1)
    #expect(item.components.relationshipStrength == 1)
    #expect(item.components.recencyVelocity == 1)
    #expect(item.components.qualityPresentation == 1)
    #expect(item.components.interestMatch == 1)
    #expect(item.score == 1)
  }

  @Test("participant breadth has the largest isolated effect")
  func breadthWeight() throws {
    let one = candidate(
      "one",
      signals: [signal("one", relationship: .direct, age: 0)]
    )
    let eight = candidate(
      "eight",
      signals: (0..<8).map { signal("actor-\($0)", relationship: .direct, age: 0) }
    )
    let result = try CircleRanker.rank(candidates: [one, eight], asOf: now)
    #expect(result.items.map(\.candidate.canonicalKey) == ["eight", "one"])
    let scores = Dictionary(
      uniqueKeysWithValues: result.items.map { ($0.candidate.canonicalKey, $0.score) }
    )
    #expect(try #require(scores["eight"]) > (try #require(scores["one"])))
  }

  @Test("invalid candidate input is rejected without destabilizing valid ranking")
  func invalidCandidate() throws {
    let invalid = candidate(
      "invalid",
      signals: [signal("actor", relationship: .direct, age: 0)],
      quality: .nan
    )
    let valid = candidate(
      "valid",
      signals: [signal("actor", relationship: .direct, age: 0)]
    )
    let result = try CircleRanker.rank(candidates: [invalid, valid], asOf: now)
    #expect(result.items.map(\.candidate.canonicalKey) == ["valid"])
    #expect(result.diagnostics.rejectedForInvalidInput == 1)
  }

  private func candidate(
    _ key: String,
    signals: [CircleParticipantSignal],
    quality: Double = 0.5,
    presentation: Double = 0.5,
    interest: Double = 0
  ) -> CircleRankCandidate {
    CircleRankCandidate(
      canonicalKey: key,
      participantSignals: signals,
      quality: quality,
      presentation: presentation,
      interestMatch: interest
    )
  }

  private func signal(
    _ participant: String,
    relationship: CircleRelationship,
    age: TimeInterval
  ) -> CircleParticipantSignal {
    CircleParticipantSignal(
      participantKey: participant,
      relationship: relationship,
      occurredAt: now.addingTimeInterval(-age)
    )
  }
}
