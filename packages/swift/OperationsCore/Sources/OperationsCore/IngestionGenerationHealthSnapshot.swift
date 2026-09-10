import Foundation

/// Live worker health for one generation, excluding retained terminal-history counts.
/// Dashboard and recovery history continue to use IngestionDurabilitySnapshot.
public struct IngestionGenerationHealthSnapshot: Sendable, Equatable {
  public let checkpoint: JetstreamDurabilityCheckpoint?
  public let pending: Int
  public let leased: Int
  public let retrying: Int
  public let deadLetters: Int
  public let oldestPendingAt: Date?
  public let observedAt: Date

  public init(
    checkpoint: JetstreamDurabilityCheckpoint?, pending: Int, leased: Int,
    retrying: Int, deadLetters: Int, oldestPendingAt: Date?, observedAt: Date
  ) {
    self.checkpoint = checkpoint
    self.pending = pending
    self.leased = leased
    self.retrying = retrying
    self.deadLetters = deadLetters
    self.oldestPendingAt = oldestPendingAt
    self.observedAt = observedAt
  }
}
