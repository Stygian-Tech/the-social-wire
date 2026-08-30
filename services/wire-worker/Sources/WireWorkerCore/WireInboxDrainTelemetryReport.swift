import Foundation

struct WireInboxDrainTelemetryReport: Equatable, Sendable {
  let intervalSeconds: TimeInterval
  let appliedEventCount: Int
  let appliedEventsPerSecond: Double
  let backlog: WireInboxBacklogHealth
}
