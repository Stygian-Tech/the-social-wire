import Foundation
import Logging

enum WireInboxDrainRuntime {
  struct Configuration: Equatable, Sendable {
    var idleMilliseconds: Int = 250
    var initialErrorBackoffMilliseconds: Int = 1_000
    var maximumErrorBackoffMilliseconds: Int = 30_000
  }

  static func run(
    processor: any WireInboxProcessing,
    state: WireWorkerHealthState,
    logger: Logger,
    configuration: Configuration,
    telemetry: WireInboxDrainTelemetryState? = nil,
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    iterationLimit: Int? = nil
  ) async throws {
    var completedIterations = 0
    var errorBackoff = max(1, configuration.initialErrorBackoffMilliseconds)
    while !Task.isCancelled,
      iterationLimit.map({ completedIterations < $0 }) ?? true
    {
      let startedAt = Date()
      await state.recordDrainStarted(at: startedAt)
      do {
        let result = try await processor.processWithMetrics(asOf: startedAt)
        if let telemetry {
          await telemetry.recordAppliedEvents(result.appliedEventCount)
        }
        await state.recordDrainSuccess(at: Date())
        errorBackoff = max(1, configuration.initialErrorBackoffMilliseconds)
        completedIterations += 1
        if result.attemptedEventCount == 0 {
          try await sleeper.sleep(milliseconds: max(1, configuration.idleMilliseconds))
        } else {
          logger.debug(
            "The Wire inbox batch processed",
            metadata: [
              "attempted_event_count": .string(String(result.attemptedEventCount)),
              "applied_event_count": .string(String(result.appliedEventCount)),
            ]
          )
          await Task.yield()
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        await state.recordDrainFailure(error)
        logger.error(
          "The Wire inbox drain failed",
          metadata: ["retry_milliseconds": .string(String(errorBackoff))]
        )
        completedIterations += 1
        try await sleeper.sleep(milliseconds: errorBackoff)
        errorBackoff = min(
          max(errorBackoff, 1) * 2,
          max(configuration.maximumErrorBackoffMilliseconds, 1)
        )
      }
    }
  }
}
