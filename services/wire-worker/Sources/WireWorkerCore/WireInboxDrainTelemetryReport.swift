import Foundation

struct WireInboxDrainTelemetryReport: Equatable, Sendable {
  let intervalSeconds: TimeInterval
  let appliedEventCount: Int
  let deferredEventCount: Int
  let appliedEventsPerSecond: Double
  let backlog: WireInboxBacklogHealth
}
