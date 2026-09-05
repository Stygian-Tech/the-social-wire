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
    clock: any WireInboxDrainClock = SystemWireInboxDrainClock(),
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    iterationLimit: Int? = nil
  ) async throws {
    var iterations = 0
    var retryMilliseconds = 60_000
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      let startedAt = await clock.now()
      let started = ContinuousClock.now
      let delayMilliseconds: Int
      do {
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
        delayMilliseconds = Int(delay * 1_000)
        retryMilliseconds = 60_000
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        await state.recordGraphFailure(error)
        logger.error("The Wire graph maintenance failed", metadata: [
          "error": .string(String(reflecting: error).prefix(500).description),
          "retry_milliseconds": .stringConvertible(retryMilliseconds),
        ])
        delayMilliseconds = retryMilliseconds
        retryMilliseconds = min(retryMilliseconds * 2, 300_000)
      }
      iterations += 1
      try await sleeper.sleep(milliseconds: delayMilliseconds)
    }
  }
}
