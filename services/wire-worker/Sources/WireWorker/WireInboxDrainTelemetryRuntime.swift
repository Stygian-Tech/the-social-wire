import Logging

enum WireInboxDrainTelemetryRuntime {
  struct Configuration: Equatable, Sendable {
    var intervalMilliseconds = 60_000
  }

  static func run(
    observer: any WireInboxBacklogObserving,
    telemetry: WireInboxDrainTelemetryState,
    logger: Logger,
    configuration: Configuration = .init(),
    clock: any WireInboxDrainClock = SystemWireInboxDrainClock(),
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    iterationLimit: Int? = nil
  ) async throws {
    var iterations = 0
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      try await sleeper.sleep(milliseconds: max(1, configuration.intervalMilliseconds))
      if Task.isCancelled { throw CancellationError() }
      let snapshotAt = await clock.now()
      do {
        let backlog = try await observer.actionableBacklogHealth(asOf: snapshotAt)
        // Include drain progress made while the independent backlog query was
        // running in both the count and its elapsed-time denominator.
        let finishedAt = await clock.now()
        let report = await telemetry.finishInterval(at: finishedAt, backlog: backlog)
        logger.info(
          "The Wire drain interval health",
          metadata: [
            "interval_seconds": .string("\(report.intervalSeconds)"),
            "applied_event_count": .string("\(report.appliedEventCount)"),
            "applied_events_per_second": .string("\(report.appliedEventsPerSecond)"),
            "actionable_backlog_count": .string("\(report.backlog.actionableEventCount)"),
            "actionable_backlog_oldest_age_seconds": .string(
              report.backlog.oldestActionableAgeSeconds.map { "\($0)" } ?? "none"
            ),
          ]
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Observability must never interrupt draining or make readiness unhealthy.
        // Preserve the interval count so the next successful snapshot covers the
        // complete elapsed window.
        logger.warning(
          "The Wire drain backlog snapshot unavailable",
          metadata: ["telemetry_error": .string("backlog_snapshot_failed")]
        )
      }
      iterations += 1
    }
  }
}
