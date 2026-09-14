import Foundation

public protocol TapRepositoryRestorer: Sendable {
  func restoreCurrentRepository(repoDid: String) async throws -> PDSReconciliationReport
  func restoreCurrentRepository(repoDid: String, recovery: PDSRepositoryRecoveryContext) async throws
    -> PDSReconciliationReport
}

extension TapRepositoryRestorer {
  public func restoreCurrentRepository(repoDid: String, recovery: PDSRepositoryRecoveryContext)
    async throws -> PDSReconciliationReport {
    try await restoreCurrentRepository(repoDid: repoDid)
  }
}

public struct TapPDSRepositoryRestorer: TapRepositoryRestorer, Sendable {
  private let store: any ThinAppViewStore
  private let backfill: ThinAppViewEnrollBackfill
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private let maxConcurrency: Int
  private let rateLimitPerSecond: Int
  private let timeoutSeconds: TimeInterval

  public init(
    store: any ThinAppViewStore,
    backfill: ThinAppViewEnrollBackfill,
    projectionCache: (any AppViewProjectionCacheStore)? = nil,
    maxConcurrency: Int,
    rateLimitPerSecond: Int,
    timeoutSeconds: TimeInterval = 120
  ) {
    self.store = store
    self.backfill = backfill
    self.projectionCache = projectionCache
    self.maxConcurrency = max(1, maxConcurrency)
    self.rateLimitPerSecond = max(1, rateLimitPerSecond)
    self.timeoutSeconds = max(0.01, timeoutSeconds)
  }

  public func restoreCurrentRepository(repoDid: String) async throws
    -> PDSReconciliationReport
  {
    try await withThrowingTaskGroup(of: PDSReconciliationReport.self) { group in
      group.addTask { try await performRestore(repoDid: repoDid) }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        throw TapRepositoryRestorationError.timedOut
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw TapRepositoryRestorationError.unavailable
      }
      return first
    }
  }

  public func restoreCurrentRepository(repoDid: String, recovery context: PDSRepositoryRecoveryContext)
    async throws -> PDSReconciliationReport {
    guard repoDid == context.repoDid, let recoveryStore = store as? any PDSRepositoryRecoveryStore else {
      throw PDSRepositoryRecoveryError.unavailable
    }
    let state = try await recoveryStore.loadRepositoryRecovery(context)
    let recovery = PDSRepositoryRecovery(context: context, store: recoveryStore, state: state)
    return try await withThrowingTaskGroup(of: PDSReconciliationReport.self) { group in
      group.addTask {
        let defaults = backfill.diagnosticOptions(maxConcurrency: maxConcurrency,
          rateLimitPerSecond: rateLimitPerSecond)
        let report = try await backfill.reconcile(authorDids: [repoDid], options: .init(
          maxConcurrency: 1, rateLimitPerSecond: rateLimitPerSecond,
          recordCapPerAuthor: min(200, defaults.recordCapPerAuthor)), recovery: recovery)
        guard report.complete else { throw TapRepositoryRestorationError.incomplete(report) }
        if !state.completed { try await recovery.finish() }
        try await store.markUnreadCountersDirtyForAuthor(authorDid: repoDid)
        try await projectionCache?.invalidateAllProjectionCaches()
        return report
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        throw TapRepositoryRestorationError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw TapRepositoryRestorationError.unavailable }
      return result
    }
  }

  private func performRestore(repoDid: String) async throws -> PDSReconciliationReport {
    let snapshotStartedAt = Date()
    let observedURIs = ObservedRepositoryURIs()
    let report = try await backfill.reconcile(
      authorDids: [repoDid],
      options: backfill.diagnosticOptions(
        maxConcurrency: maxConcurrency,
        rateLimitPerSecond: rateLimitPerSecond
      ),
      onProgress: { progress in
        await observedURIs.insert(progress.lastRecordUri)
      }
    )
    guard report.complete else {
      throw TapRepositoryRestorationError.incomplete(report)
    }

    // Never clear existing rows before the PDS has supplied a complete snapshot: a large response,
    // invalid historical record, or transient PDS failure must leave the last good projection intact.
    // The indexed-at cutoff also preserves later commits applied concurrently by another worker.
    try Task.checkCancellation()
    let currentURIs = await observedURIs.values.sorted()
    try Task.checkCancellation()
    _ = try await store.deleteContentItems(
      authorDid: repoDid,
      excludingURIs: currentURIs,
      indexedAtOrBefore: snapshotStartedAt
    )
    try Task.checkCancellation()
    try await store.markUnreadCountersDirtyForAuthor(authorDid: repoDid)
    try Task.checkCancellation()
    try await projectionCache?.invalidateAllProjectionCaches()
    return report
  }
}

private actor ObservedRepositoryURIs {
  private(set) var values: Set<String> = []

  func insert(_ uri: String) {
    values.insert(uri)
  }
}

public enum TapRepositoryRestorationError: Error, Sendable {
  case unavailable
  case incomplete(PDSReconciliationReport)
  case timedOut
}
