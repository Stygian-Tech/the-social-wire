import Foundation
import Logging
import OperationsCore

struct OperationsRetentionJob: Sendable {
  let store: any OperationsStore
  let logger: Logger

  func runForever() async {
    while !Task.isCancelled {
      do {
        // Bound each pass as well as each SQL branch. Repeated passes drain a backlog without
        // turning retention into one large locking transaction.
        for _ in 0..<10 {
          let deleted = try await store.cleanupExpired(at: Date(), batchSize: 1_000)
          if deleted == 0 { break }
        }
      } catch {
        logger.warning(
          "Operations retention cleanup failed",
          metadata: ["error_type": .string(OperationsRedactor.errorCategory(error))])
      }
      try? await Task.sleep(for: .seconds(3_600))
    }
  }
}
