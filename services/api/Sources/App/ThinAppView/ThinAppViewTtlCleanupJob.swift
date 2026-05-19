import Foundation
import Logging

actor ThinAppViewTtlCleanupJob {
  private let store: any ThinAppViewStore
  private let config: ThinAppViewConfig
  private let logger: Logger

  init(store: any ThinAppViewStore, config: ThinAppViewConfig, logger: Logger) {
    self.store = store
    self.config = config
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
    let contentDeleted = try await store.deleteExpiredContent(before: now)
    let readCutoff = now.addingTimeInterval(-config.readMarkRetentionSeconds)
    let readDeleted = try await store.deleteExpiredReadMarks(before: readCutoff)
    logger.info(
      "Thin AppView TTL cleanup",
      metadata: [
        "contentDeleted": .stringConvertible(contentDeleted),
        "readMarksDeleted": .stringConvertible(readDeleted),
      ]
    )
  }
}
