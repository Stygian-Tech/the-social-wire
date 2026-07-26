import Foundation

public protocol TapRepositoryRestorer: Sendable {
  func restoreCurrentRepository(repoDid: String) async throws -> PDSReconciliationReport
}

public struct TapPDSRepositoryRestorer: TapRepositoryRestorer, Sendable {
  private let store: any ThinAppViewStore
  private let backfill: ThinAppViewEnrollBackfill
  private let maxConcurrency: Int
  private let rateLimitPerSecond: Int

  public init(
    store: any ThinAppViewStore,
    backfill: ThinAppViewEnrollBackfill,
    maxConcurrency: Int,
    rateLimitPerSecond: Int
  ) {
    self.store = store
    self.backfill = backfill
    self.maxConcurrency = max(1, maxConcurrency)
    self.rateLimitPerSecond = max(1, rateLimitPerSecond)
  }

  public func restoreCurrentRepository(repoDid: String) async throws
    -> PDSReconciliationReport
  {
    // Tap delivers repository events in order and waits for this handler's acknowledgement. Resetting
    // then reconciling while that delivery is blocked makes retries idempotent and prevents a later
    // commit from racing behind the current-repository snapshot.
    _ = try await store.deleteContentItems(authorDid: repoDid)
    let report = try await backfill.reconcile(
      authorDids: [repoDid],
      options: backfill.diagnosticOptions(
        maxConcurrency: maxConcurrency,
        rateLimitPerSecond: rateLimitPerSecond
      )
    )
    guard report.complete else {
      throw TapRepositoryRestorationError.incomplete(report)
    }
    return report
  }
}

public enum TapRepositoryRestorationError: Error, Sendable {
  case unavailable
  case incomplete(PDSReconciliationReport)
}
