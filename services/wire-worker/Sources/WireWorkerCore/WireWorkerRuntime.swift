import Foundation
import Logging

enum WireWorkerRuntime {
  static func runForever(
    cycle: WireWorkerCycle,
    state: WireWorkerHealthState,
    logger: Logger
  ) async throws {
    let clock = ContinuousClock()
    while !Task.isCancelled {
      let cycleStart = clock.now
      let startedAt = Date()
      do {
        let outcome = try await cycle.run(asOf: startedAt)
        let elapsed = cycleStart.duration(to: clock.now)
        let durationMilliseconds = Double(elapsed.components.seconds) * 1_000
          + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        await state.recordGenerationSuccess(at: startedAt, durationMilliseconds: durationMilliseconds)
        switch outcome {
        case .off:
          logger.info("The Wire is remotely off")
        case .generated(let id, let itemCount, let activated):
          do {
            try await cycle.store.recordCycleDuration(
              milliseconds: durationMilliseconds, generationID: id)
          } catch {
            logger.debug("The Wire cycle duration export unavailable")
          }
          logger.info(
            "The Wire generation committed",
            metadata: [
              "generation_id": .string(id.uuidString.lowercased()),
              "item_count": .string(String(itemCount)),
              "cycle_duration_ms": .stringConvertible(durationMilliseconds),
              "activated": .string(String(activated)),
            ]
          )
        }
      } catch {
        await state.recordGenerationFailure(error)
        logger.error("The Wire generation cycle failed", metadata: ["error": .string(String(reflecting: error))])
      }
      // Work runs serially. A slow cycle starts the next pass when it finishes rather than
      // accumulating overlapping timers; normal cycles include work in the configured interval.
      let remaining = WireGenerationSchedule.remainingDelay(
        interval: .seconds(cycle.config.intervalSeconds),
        elapsed: cycleStart.duration(to: clock.now)
      )
      try await clock.sleep(for: remaining)
    }
  }
}
