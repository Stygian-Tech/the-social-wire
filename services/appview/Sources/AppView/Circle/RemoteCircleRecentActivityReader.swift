import Foundation
import WireCore

struct RemoteCircleRecentActivityReader: CircleRecentActivityReading {
  private let fetcher: any CircleCandidateFetching
  private let actorHasher: WireActorHasher

  init(fetcher: any CircleCandidateFetching, actorHasher: WireActorHasher) {
    self.fetcher = fetcher
    self.actorHasher = actorHasher
  }

  func mostRecentActivity(for actorDIDs: Set<String>) async throws -> [String: Date] {
    guard !actorDIDs.isEmpty else { return [:] }
    var didByHash: [String: String] = [:]
    for did in actorDIDs { didByHash[try actorHasher.hash(did)] = did }
    var result: [String: Date] = [:]
    for hashes in Array(didByHash.keys).circleChunks(
      maximum: WireCorpusCandidateRequest.maximumActorHashesPerRequest
    ) {
      let page = try await fetcher.candidates(
        actorHashes: hashes,
        language: "und",
        since: Date().addingTimeInterval(-7 * 24 * 60 * 60),
        limit: WireCorpusCandidateRequest.maximumStoriesPerRequest,
        now: Date()
      )
      for fact in page.stories.flatMap(\.facts) {
        guard let did = didByHash[fact.actorHash] else { continue }
        result[did] = max(result[did] ?? .distantPast, fact.occurredAt)
      }
    }
    return result
  }
}

extension Array {
  fileprivate func circleChunks(maximum: Int) -> [[Element]] {
    stride(from: 0, to: count, by: maximum).map { start in
      Array(self[start..<Swift.min(start + maximum, count)])
    }
  }
}
