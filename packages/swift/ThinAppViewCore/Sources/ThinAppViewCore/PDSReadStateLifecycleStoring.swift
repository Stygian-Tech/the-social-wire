import Foundation

public protocol PDSReadStateLifecycleStoring: PDSReadStateStoring {
  /// Coalesced by the store: at most one durable touch per viewer per hour.
  func touchPDSReadStateAccess(viewerDid: String, at: Date) async throws
  /// Evicts at most one eligible viewer and a bounded number of derived rows.
  /// Returns that viewer only when cache invalidation is needed.
  func evictIdlePDSReadState(before: Date, at: Date, batchSize: Int) async throws -> PDSReadStateEvictionBatch
}
