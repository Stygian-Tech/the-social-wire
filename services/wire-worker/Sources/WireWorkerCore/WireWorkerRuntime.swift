import Foundation
import Logging

enum WireWorkerRuntime {
  static func runForever(
    cycle: WireWorkerCycle,
    state: WireWorkerHealthState,
    scheduler: WireRankingScheduler = WireRankingScheduler(),
    logger: Logger
  ) async throws {
    try await runScheduled(
      intervalSeconds: cycle.config.intervalSeconds, scheduler: scheduler,
      operation: {
        let cycleStart = ContinuousClock.now
        let startedAt = Date()
        let outcome = try await cycle.run(asOf: startedAt)
        try Task.checkCancellation()
        let elapsed = cycleStart.duration(to: .now)
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
      }, onFailure: { error in
        await state.recordGenerationFailure(error)
        logger.error("The Wire generation cycle failed", metadata: ["error": .string(String(reflecting: error))])
      })
  }

  static func runScheduled(
    intervalSeconds: Int,
    scheduler: WireRankingScheduler,
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    monotonicNow: @Sendable () async -> ContinuousClock.Instant = { .now },
    iterationLimit: Int? = nil,
    operation: @Sendable () async throws -> Void,
    onFailure: @Sendable (any Error) async -> Void = { _ in }
  ) async throws {
    var iterations = 0
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      let reservation = await scheduler.reserve(at: monotonicNow())
      guard case .run(let token) = reservation else {
        if case .wait(let milliseconds) = reservation {
          try await sleeper.sleep(milliseconds: milliseconds)
        }
        continue
      }
      do {
        try Task.checkCancellation()
        // The operation returns only after every language/plan and its awaited
        // cleanup complete. A single published generation is not cycle success.
        try await operation()
        try Task.checkCancellation()
        await scheduler.succeeded(token, at: monotonicNow(), intervalSeconds: intervalSeconds)
      } catch {
        let canceled = error is CancellationError || Task.isCancelled
        if !canceled { await onFailure(error) }
        await scheduler.failed(token, at: monotonicNow())
        if canceled || Task.isCancelled { throw CancellationError() }
      }
      iterations += 1
    }
  }
}
