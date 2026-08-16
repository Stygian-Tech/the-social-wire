import NIOHTTP1
import Foundation
import OperationsCore
import Testing
@testable import AppViewWorker

@Suite("Charybdis health responses")
struct WorkerHealthServerTests {
  @Test("liveness is independent of database readiness")
  func liveness() async {
    let response = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/livez",
      readinessProbe: { throw ProbeError.unavailable }
    )
    #expect(response.status == .ok)
  }

  @Test("readiness requires a successful database probe")
  func readiness() async {
    let ready = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      readinessProbe: {}
    )
    #expect(ready.status == .ok)

    let unavailable = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      readinessProbe: { throw ProbeError.unavailable }
    )
    #expect(unavailable.status == .serviceUnavailable)
  }

  @Test("readiness rejects stale or unhealthy ingestion evidence")
  func ingestionEvidence() async throws {
    let now = Date()
    let healthy = serviceState(heartbeatAt: now, readiness: .healthy)
    try await WorkerReadinessProbe(
      databaseProbe: {},
      serviceStateProbe: { healthy },
      now: { now }
    ).run()

    let stale = serviceState(heartbeatAt: now.addingTimeInterval(-16), readiness: .healthy)
    await #expect(throws: WorkerReadinessError.staleIngestionHeartbeat) {
      try await WorkerReadinessProbe(
        databaseProbe: {},
        serviceStateProbe: { stale },
        now: { now }
      ).run()
    }

    let unhealthy = serviceState(heartbeatAt: now, readiness: .degraded)
    await #expect(throws: WorkerReadinessError.ingestionUnhealthy) {
      try await WorkerReadinessProbe(
        databaseProbe: {},
        serviceStateProbe: { unhealthy },
        now: { now }
      ).run()
    }

    let staleProjection = serviceState(
      heartbeatAt: now,
      readiness: .healthy,
      freshness: .degraded
    )
    await #expect(throws: WorkerReadinessError.ingestionUnhealthy) {
      try await WorkerReadinessProbe(
        databaseProbe: {},
        serviceStateProbe: { staleProjection },
        now: { now }
      ).run()
    }

    let incompleteProjection = serviceState(
      heartbeatAt: now,
      readiness: .healthy,
      completeness: .degraded
    )
    await #expect(throws: WorkerReadinessError.ingestionUnhealthy) {
      try await WorkerReadinessProbe(
        databaseProbe: {},
        serviceStateProbe: { incompleteProjection },
        now: { now }
      ).run()
    }
  }

  private func serviceState(
    heartbeatAt: Date,
    readiness: OperationsHealthState,
    freshness: OperationsHealthState = .healthy,
    completeness: OperationsHealthState = .healthy
  ) -> OperationsServiceState {
    OperationsServiceState(
      service: "appview-worker",
      environment: "dev",
      instanceId: "worker-1",
      liveness: readiness,
      readiness: readiness,
      freshness: freshness,
      completeness: completeness,
      startedAt: heartbeatAt.addingTimeInterval(-60),
      heartbeatAt: heartbeatAt
    )
  }
}

private enum ProbeError: Error {
  case unavailable
}
