import Foundation
import Logging

actor ThinAppViewTtlCleanupJob {
  private let store: any ThinAppViewStore
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private let config: ThinAppViewConfig
  private let tapStorageEnabled: Bool
  private let environment: String
  private let batchSize: Int
  private let logger: Logger

  init(
    store: any ThinAppViewStore,
    projectionCache: (any AppViewProjectionCacheStore)?,
    config: ThinAppViewConfig,
    tapStorageEnabled: Bool = false,
    environment: String,
    batchSize: Int = 1_000,
    logger: Logger
  ) {
    self.store = store
    self.projectionCache = projectionCache
    self.config = config
    self.tapStorageEnabled = tapStorageEnabled
    self.environment = environment
    self.batchSize = max(1, min(batchSize, 10_000))
    self.logger = logger
  }

  func runForever() async {
    while !Task.isCancelled {
      do {
        try await runOnce()
      } catch {
        logger.warning("TTL cleanup failed", metadata: ["error": .string("\(error)")])
      }
      try? await Task.sleep(for: .seconds(3600))
    }
  }

  func runOnce() async throws {
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
    let projectionCachesDeleted = try await projectionCache?.deleteExpiredProjectionCaches(
      before: now,
      batchSize: batchSize
    ) ?? 0
    logger.info(
      "Thin AppView TTL cleanup",
      metadata: [
        "contentDeleted": .stringConvertible(contentDeleted),
        "readMarksDeleted": .stringConvertible(readDeleted),
        "tapReceiptsDeleted": .stringConvertible(tapReceiptsDeleted),
        "projectionRepairsDeleted": .stringConvertible(projectionRepairsDeleted),
        "projectionCachesDeleted": .stringConvertible(projectionCachesDeleted),
      ]
    )
  }
}
