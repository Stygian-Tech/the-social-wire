import Foundation

actor WireInboxDrainTelemetryState {
  private var intervalStartedAt: Date
  private var appliedEventCount = 0

  init(startedAt: Date) {
    intervalStartedAt = startedAt
  }

  func recordAppliedEvents(_ count: Int) {
    appliedEventCount += max(0, count)
  }

  func finishInterval(
    at finishedAt: Date,
    backlog: WireInboxBacklogHealth
  ) -> WireInboxDrainTelemetryReport {
    let interval = max(0.001, finishedAt.timeIntervalSince(intervalStartedAt))
    let report = WireInboxDrainTelemetryReport(
      intervalSeconds: interval,
      appliedEventCount: appliedEventCount,
      appliedEventsPerSecond: Double(appliedEventCount) / interval,
      backlog: backlog
    )
    intervalStartedAt = finishedAt
    appliedEventCount = 0
    return report
  }
}
