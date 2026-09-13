import Foundation
import Logging
import WireCore

/// Run as a child of WireWorkerHost's task group, under the Coordinator's materializer lease.
/// Serial awaits prevent overlap; lease loss cancels both in-flight work and the cadence sleep.
enum WireGraphMaintenanceRuntime {
  static func run(
    maintainer: any WireGraphMaintaining,
    state: WireWorkerHealthState,
    logger: Logger,
    scheduler: WireGraphMaintenanceScheduler = WireGraphMaintenanceScheduler(),
    clock: any WireInboxDrainClock = SystemWireInboxDrainClock(),
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    monotonicNow: @Sendable () async -> ContinuousClock.Instant = { .now },
    iterationLimit: Int? = nil
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
      let startedAt = await clock.now()
      let started = ContinuousClock.now
      do {
        try Task.checkCancellation()
        let nextRunAt = try await maintainer.maintainGraph(asOf: startedAt)
        try Task.checkCancellation()
        let completedAt = await clock.now()
        let elapsed = started.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
          + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        await state.recordGraphSuccess(at: completedAt, durationMilliseconds: milliseconds)
        logger.info("The Wire graph maintenance completed", metadata: [
          "duration_ms": .stringConvertible(milliseconds),
        ])
        let delay = min(WireDataPolicy.clusteringCadence, max(1, nextRunAt.timeIntervalSince(completedAt)))
        await scheduler.succeeded(token, at: monotonicNow(), nextDelayMilliseconds: Int(delay * 1_000))
      } catch {
        let retryMilliseconds = await scheduler.failed(token, at: monotonicNow()) ?? 60_000
        if error is CancellationError || Task.isCancelled {
          logger.info("The Wire graph maintenance canceled with retry retained", metadata: [
            "retry_milliseconds": .stringConvertible(retryMilliseconds),
          ])
          throw CancellationError()
        }
        await state.recordGraphFailure(error)
        logger.error("The Wire graph maintenance failed", metadata: [
          "error": .string(String(reflecting: error).prefix(500).description),
          "retry_milliseconds": .stringConvertible(retryMilliseconds),
        ])
      }
      iterations += 1
    }
  }
}
