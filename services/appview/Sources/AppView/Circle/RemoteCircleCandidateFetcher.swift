import Foundation
import WireCore

struct RemoteCircleCandidateFetcher: CircleCandidateFetching {
  let transport: any WireCorpusTransport

  func candidates(
    actorHashes: [String],
    language: String,
    since: Date,
    limit: Int,
    now: Date
  ) async throws -> WireCorpusCandidateResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var storiesByID: [String: WireCorpusCandidateStory] = [:]
    var generatedAt = Date.distantPast
    var generationID: String?
    for chunk in actorHashes.chunked(
      maximum: WireCorpusCandidateRequest.maximumActorHashesPerRequest)
    {
      let input = WireCorpusCandidateRequest(
        actorHashes: chunk,
        language: language,
        since: since,
        limit: limit
      )
      let response = try await transport.post(
        target: "/internal/wire/v1/circle-candidates",
        body: try encoder.encode(input)
      )
      guard response.statusCode == 200, response.contractVersion == 3 else {
        throw WireServingError.corpusContractMismatch
      }
      let page = try decoder.decode(WireCorpusCandidateResponse.self, from: response.body)
      if let generationID, generationID != page.generationID {
        throw WireServingError.corpusContractMismatch
      }
      generationID = page.generationID
      generatedAt = max(generatedAt, page.generatedAt)
      for story in page.stories {
        if let existing = storiesByID[story.item.itemID] {
          var factsByKey: [String: WireCorpusSignalFact] = [:]
          for fact in existing.facts + story.facts {
            factsByKey[
              "\(fact.actorHash)\n\(fact.sourceURI)\n\(fact.occurredAt.timeIntervalSince1970)"] =
              fact
          }
          let facts = factsByKey.values.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            if $0.actorHash != $1.actorHash { return $0.actorHash < $1.actorHash }
            return $0.sourceURI < $1.sourceURI
          }
          storiesByID[story.item.itemID] = WireCorpusCandidateStory(
            item: existing.item,
            topicKeys: Array(Set(existing.topicKeys + story.topicKeys)).sorted(),
            facts: facts
          )
        } else {
          storiesByID[story.item.itemID] = story
        }
      }
    }
    let stories = storiesByID.values.sorted { lhs, rhs in
      let lhsParticipants = Set(lhs.facts.map(\.actorHash)).count
      let rhsParticipants = Set(rhs.facts.map(\.actorHash)).count
      if lhsParticipants != rhsParticipants { return lhsParticipants > rhsParticipants }
      let lhsLatest = lhs.facts.map(\.occurredAt).max() ?? .distantPast
      let rhsLatest = rhs.facts.map(\.occurredAt).max() ?? .distantPast
      if lhsLatest != rhsLatest { return lhsLatest > rhsLatest }
      return lhs.item.itemID < rhs.item.itemID
    }
    return WireCorpusCandidateResponse(
      generationID: generationID ?? "circle-\(Int(now.timeIntervalSince1970 / 300))",
      generatedAt: generationID == nil ? now : generatedAt,
      language: language,
      stories: Array(stories.prefix(limit)),
      exhausted: stories.count < limit
    )
  }
}

extension Array {
  fileprivate func chunked(maximum: Int) -> [[Element]] {
    guard !isEmpty else { return [] }
    return stride(from: 0, to: count, by: maximum).map { start in
      Array(self[start..<Swift.min(start + maximum, count)])
    }
  }
}
