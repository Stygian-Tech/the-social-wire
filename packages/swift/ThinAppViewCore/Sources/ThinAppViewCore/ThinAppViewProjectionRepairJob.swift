import Foundation
import Logging
import OperationsCore

/// Drains durable projection-repair work created in the same transaction as Tap content writes.
actor ThinAppViewProjectionRepairJob {
  private let store: any ThinAppViewStore
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private let operationsStore: (any OperationsStore)?
  private let environment: String
  private let workerId: String
  private let telemetry: OperationsTelemetryBuffer?
  private let logger: Logger

  init(
    store: any ThinAppViewStore,
    projectionCache: (any AppViewProjectionCacheStore)?,
    operationsStore: (any OperationsStore)? = nil,
    environment: String,
    workerId: String,
    telemetry: OperationsTelemetryBuffer?,
    logger: Logger
  ) {
    self.store = store
    self.projectionCache = projectionCache
    self.operationsStore = operationsStore
    self.environment = environment
    self.workerId = workerId
    self.telemetry = telemetry
    self.logger = logger
  }

  func runForever() async {
    while !Task.isCancelled {
      do {
        if let repair = try await store.claimProjectionRepair(
          environment: environment,
          workerId: workerId,
          leaseUntil: Date().addingTimeInterval(60),
          at: Date()
        ) {
          await execute(repair)
        } else {
          try await Task.sleep(for: .seconds(1))
        }
      } catch {
        logger.warning(
          "Projection repair polling failed",
          metadata: ["error_type": .string(String(describing: type(of: error)))]
        )
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func execute(_ repair: AppViewProjectionRepair) async {
    do {
      try await store.markUnreadCountersDirtyForContent(
        authorDid: repair.authorDid,
        publicationSite: repair.publicationSite
      )
      try await invalidateCaches(publicationSite: repair.publicationSite)
      try await store.completeProjectionRepair(
        environment: environment,
        id: repair.id,
        workerId: workerId
      )
      try? await operationsStore?.markStreamProjectionWatermark(
        source: "tap",
        watermark: "event:\(repair.eventId)",
        at: Date()
      )
      await emitResult("success")
    } catch {
      let delay = min(300, pow(2, Double(repair.attempts + 1)))
      try? await store.failProjectionRepair(
        environment: environment,
        id: repair.id,
        workerId: workerId,
        errorCategory: String(describing: type(of: error)),
        retryAt: Date().addingTimeInterval(delay),
        at: Date()
      )
      await emitResult("error")
    }
  }

  private func invalidateCaches(publicationSite: String?) async throws {
    guard let projectionCache else { return }
    guard let publicationSite else {
      try await projectionCache.invalidateAllProjectionCaches()
      return
    }
    var publicationIds = RenderFieldExtractor.publicationFilterEquivalenceKeys(
      publicationAtUri: publicationSite
    )
    if let canonical = RenderFieldExtractor.canonicalPublicationAtUriKey(publicationSite) {
      publicationIds.insert(canonical)
    }
    if let normalized = RenderFieldExtractor.normalizePublicationSiteUrl(publicationSite) {
      publicationIds.insert(normalized)
    }
    if publicationIds.isEmpty {
      try await projectionCache.invalidateAllProjectionCaches()
      return
    }
    for publicationId in publicationIds {
      try await projectionCache.invalidateFirstPageForAllViewers(publicationId: publicationId)
    }
  }

  private func emitResult(_ result: String) async {
    _ = await telemetry?.enqueue(
      .metric(
        .init(
          name: "socialwire.ingestion.results_total",
          value: 1,
          dimensions: [
            "ingestion_source": "projection_repair",
            "result": result,
          ]
        )
      )
    )
  }
}
