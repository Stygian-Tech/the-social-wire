import Foundation
import WireCore

protocol CircleCandidateFetching: Sendable {
  func candidates(
    actorHashes: [String],
    language: String,
    since: Date,
    limit: Int,
    now: Date
  ) async throws -> WireCorpusCandidateResponse
}
