import Foundation

protocol WireInboxRepositoryProcessing: Sendable {
  func claimWork(asOf: Date, limit: Int, afterRepository: WireInboxRepository?) async throws
    -> WireInboxWorkBatch
  func claimNext(in repository: WireInboxRepository, asOf: Date) async throws -> WireInboxEvent?
  func applyClaimed(_ event: WireInboxEvent, asOf: Date) async throws -> WireInboxEventOutcome
}
