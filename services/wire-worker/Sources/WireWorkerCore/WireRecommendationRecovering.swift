import Foundation

protocol WireRecommendationRecovering: Sendable {
  func backlog(asOf: Date, sourceScope: WireInboxSourceScope?) async throws -> WireRecommendationBacklog
  func recover(asOf: Date, limit: Int, sourceScope: WireInboxSourceScope?) async throws
    -> WireRecommendationRecoveryCounts
}

extension PostgresWireRecommendationJournal: WireRecommendationRecovering {}

