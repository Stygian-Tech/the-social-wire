import Foundation
import OperationsCore

struct WorkerReadinessProbe: Sendable {
  let databaseProbe: @Sendable () async throws -> Void
  let serviceStateProbe: (@Sendable () async throws -> OperationsServiceState?)?
  let now: @Sendable () -> Date

  init(
    databaseProbe: @escaping @Sendable () async throws -> Void,
    serviceStateProbe: (@Sendable () async throws -> OperationsServiceState?)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.databaseProbe = databaseProbe
    self.serviceStateProbe = serviceStateProbe
    self.now = now
  }

  func run() async throws {
    try await databaseProbe()
    guard let serviceStateProbe else { return }
    guard let state = try await serviceStateProbe() else {
      throw WorkerReadinessError.missingIngestionHeartbeat
    }

    let heartbeatAge = now().timeIntervalSince(state.heartbeatAt)
    guard heartbeatAge >= -5, heartbeatAge <= 15 else {
      throw WorkerReadinessError.staleIngestionHeartbeat
    }
    guard
      state.liveness == .healthy,
      state.readiness == .healthy,
      state.freshness == .healthy,
      state.completeness == .healthy
    else {
      throw WorkerReadinessError.ingestionUnhealthy
    }
  }
}

enum WorkerReadinessError: Error, Equatable {
  case missingIngestionHeartbeat
  case staleIngestionHeartbeat
  case ingestionUnhealthy
}
