import Foundation
import Logging

actor ThinAppViewTtlCleanupJob {
  private let store: any ThinAppViewStore
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private let config: ThinAppViewConfig
  private let tapStorageEnabled: Bool
  private let environment: String
  private let batchSize: Int
  private let timeBudget: Duration
  private let logger: Logger

  init(
    store: any ThinAppViewStore,
    projectionCache: (any AppViewProjectionCacheStore)?,
    config: ThinAppViewConfig,
    tapStorageEnabled: Bool = false,
    environment: String,
    batchSize: Int = 1_000,
    timeBudget: Duration = .seconds(30),
    logger: Logger
  ) {
    self.store = store
    self.projectionCache = projectionCache
    self.config = config
    self.tapStorageEnabled = tapStorageEnabled
    self.environment = environment
    self.batchSize = max(1, min(batchSize, 10_000))
    self.timeBudget = timeBudget
    self.logger = logger
  }

  func runForever() async {
    while !Task.isCancelled {
      var mayHaveBacklog = true
      do {
        mayHaveBacklog = try await runOnce()
      } catch {
        logger.warning("TTL cleanup failed", metadata: ["error": .string("\(error)")])
      }
      // Drain promptly after a full batch or transient failure, while yielding to
      // ingestion between sweeps. An empty sweep can use the normal hourly cadence.
      try? await Task.sleep(for: .seconds(mayHaveBacklog ? 10 : 3600))
    }
  }

  @discardableResult
  func runOnce() async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeBudget)
    var batches = 0
    var totalDeleted = 0
    var mayHaveBacklog: Bool
    repeat {
      try Task.checkCancellation()
      let counts = try await deleteBatch()
      totalDeleted += counts.reduce(0, +)
      batches += 1
      mayHaveBacklog = counts.contains { $0 >= batchSize }
    } while mayHaveBacklog && clock.now < deadline
    logger.info(
      "Thin AppView TTL cleanup sweep",
      metadata: [
        "batches": .stringConvertible(batches),
        "deleted": .stringConvertible(totalDeleted),
        "mayHaveBacklog": .stringConvertible(mayHaveBacklog),
      ]
    )
    return mayHaveBacklog
  }

  private func deleteBatch() async throws -> [Int] {
    let now = Date()
    let contentDeleted = try await store.deleteExpiredContent(before: now, batchSize: batchSize)
    let readCutoff = now.addingTimeInterval(-config.readMarkRetentionSeconds)
    let readDeleted = try await store.deleteExpiredReadMarks(
      before: readCutoff,
      batchSize: batchSize
    )
    let tapReceiptsDeleted = if tapStorageEnabled {
      try await store.deleteExpiredTapEventReceipts(
        environment: environment,
        before: now,
        batchSize: batchSize
      )
    } else {
      0
    }
    let projectionRepairsDeleted = if tapStorageEnabled {
      try await store.deleteExpiredProjectionRepairs(
        environment: environment,
        before: now,
        batchSize: batchSize
      )
    } else {
      0
    }
    let ingestionInboxDeleted = try await store.deleteExpiredIngestionInbox(
      environment: environment,
      before: now,
      batchSize: batchSize
    )
    let circleCachesDeleted = try await store.deleteExpiredCircleCaches(
      before: now,
      batchSize: batchSize
    )
    let projectionCachesDeleted = try await projectionCache?.deleteExpiredProjectionCaches(
      before: now,
      batchSize: batchSize
    ) ?? 0
    logger.debug(
      "Thin AppView TTL cleanup batch",
      metadata: [
        "contentDeleted": .stringConvertible(contentDeleted),
        "readMarksDeleted": .stringConvertible(readDeleted),
        "tapReceiptsDeleted": .stringConvertible(tapReceiptsDeleted),
        "projectionRepairsDeleted": .stringConvertible(projectionRepairsDeleted),
        "ingestionInboxDeleted": .stringConvertible(ingestionInboxDeleted),
        "projectionCachesDeleted": .stringConvertible(projectionCachesDeleted),
        "circleCachesDeleted": .stringConvertible(circleCachesDeleted),
      ]
    )
    return [contentDeleted, readDeleted, tapReceiptsDeleted,
      projectionRepairsDeleted, ingestionInboxDeleted, projectionCachesDeleted, circleCachesDeleted]
  }
}
