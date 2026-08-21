import Foundation
import Logging

enum WireWorkerRuntime {
  static func runForever(
    cycle: WireWorkerCycle,
    state: WireWorkerHealthState,
    logger: Logger
  ) async throws {
    while !Task.isCancelled {
      let startedAt = Date()
      do {
        let outcome = try await cycle.run(asOf: startedAt)
        await state.recordSuccess(at: startedAt)
        switch outcome {
        case .off:
          logger.info("The Wire is remotely off")
        case .generated(let id, let itemCount, let activated):
          logger.info(
            "The Wire generation committed",
            metadata: [
              "generation_id": .string(id.uuidString.lowercased()),
              "item_count": .string(String(itemCount)),
              "activated": .string(String(activated)),
            ]
          )
        }
      } catch {
        await state.recordFailure(error)
        logger.error("The Wire generation cycle failed", metadata: ["error": .string(String(reflecting: error))])
      }
      try await Task.sleep(for: .seconds(cycle.config.intervalSeconds))
    }
  }
}
