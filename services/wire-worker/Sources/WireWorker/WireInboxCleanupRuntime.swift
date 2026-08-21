import Foundation
import Logging

enum WireInboxCleanupRuntime {
  static func run(
    cleaner: any WireInboxCleaning,
    state: WireWorkerHealthState,
    logger: Logger,
    batchSize: Int,
    idleMilliseconds: Int,
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    iterationLimit: Int? = nil
  ) async throws {
    var iterations = 0
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      let startedAt = Date()
      await state.recordCleanupStarted(at: startedAt)
      do {
        let count = try await cleaner.deleteTerminal(asOf: startedAt, batchSize: batchSize)
        await state.recordCleanupSuccess(at: Date(), deleted: count)
        iterations += 1
        if count < batchSize {
          try await sleeper.sleep(milliseconds: max(1, idleMilliseconds))
        } else {
          await Task.yield()
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        await state.recordCleanupFailure(error)
        logger.error("The Wire terminal inbox cleanup failed")
        iterations += 1
        try await sleeper.sleep(milliseconds: max(1, idleMilliseconds))
      }
    }
  }
}
