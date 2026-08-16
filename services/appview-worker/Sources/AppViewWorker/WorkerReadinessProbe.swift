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

  func run(includingDiagnostics: Bool = false) async throws {
    try await databaseProbe()
    guard let serviceStateProbe else {
      throw WorkerReadinessError.missingIngestionHeartbeat
    }
    guard let state = try await serviceStateProbe() else {
      throw WorkerReadinessError.missingIngestionHeartbeat
    }

    let evaluatedAt = now()
    let heartbeatAge = evaluatedAt.timeIntervalSince(state.heartbeatAt)
    guard heartbeatAge >= -5, heartbeatAge <= 15 else {
      throw failure(
        .staleIngestionHeartbeat,
        state: state,
        at: evaluatedAt,
        includingDiagnostics: includingDiagnostics
      )
    }
    guard state.liveness == .healthy, state.readiness == .healthy else {
      throw failure(
        .ingestionTransportUnhealthy,
        state: state,
        at: evaluatedAt,
        includingDiagnostics: includingDiagnostics
      )
    }

    // Projection-repair evidence describes the authoritative Tap and durable V2 paths. The
    // legacy Jetstream path used during v1_authoritative/v2_shadow has no repair queue, so its
    // freshness and completeness are intentionally unknown even while its transport is healthy.
    // Keep fail-closed behavior for missing or unrecognized source metadata.
    let projectionQualityRequired = switch state.dependencyState["ingestion_source"] {
    case "jetstream": false
    default: true
    }
    if projectionQualityRequired, state.freshness != .healthy {
      throw failure(
        .ingestionFreshnessUnhealthy,
        state: state,
        at: evaluatedAt,
        includingDiagnostics: includingDiagnostics
      )
    }
    if projectionQualityRequired, state.completeness != .healthy {
      throw failure(
        .ingestionCompletenessUnhealthy,
        state: state,
        at: evaluatedAt,
        includingDiagnostics: includingDiagnostics
      )
    }
  }

  private func failure(
    _ reason: WorkerReadinessError,
    state: OperationsServiceState,
    at now: Date,
    includingDiagnostics: Bool
  ) -> any Error {
    guard includingDiagnostics, let diagnostics = WorkerReadinessDiagnostics.v2(from: state, at: now)
    else { return reason }
    return WorkerReadinessFailure(reason: reason, diagnostics: diagnostics)
  }
}

enum WorkerReadinessError: Error, Equatable {
  case missingIngestionHeartbeat
  case staleIngestionHeartbeat
  case ingestionTransportUnhealthy
  case ingestionFreshnessUnhealthy
  case ingestionCompletenessUnhealthy
}
