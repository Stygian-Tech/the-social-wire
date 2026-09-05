import Foundation
import WireCore

protocol WireGenerationStore: Sendable {
  func ping() async throws
  func eligibleLanguageBuckets(
    limit: Int,
    minimumCandidates: Int,
    ranking: WireRankingConfig,
    asOf: Date
  ) async throws -> [String]
  func loadCandidates(
    languageBucket: String,
    limit: Int,
    ranking: WireRankingConfig,
    asOf: Date
  ) async throws -> [WireCandidate]
  func commit(_ generation: WireGenerationCommit) async throws
  func recordCycleDuration(milliseconds: Double, generationID: UUID) async throws
  func deleteExpired(asOf: Date, batchSize: Int) async throws
}

extension WireGenerationStore {
  func recordCycleDuration(milliseconds: Double, generationID: UUID) async throws {}

  func eligibleLanguageBuckets(
    limit: Int,
    minimumCandidates: Int,
    ranking: WireRankingConfig,
    asOf: Date
  ) async throws -> [String] {
    []
  }
}
