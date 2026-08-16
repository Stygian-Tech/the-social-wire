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
      startupProbe: { throw ProbeError.unavailable },
      readinessProbe: { throw ProbeError.unavailable }
    )
    #expect(response.status == .ok)
  }

  @Test("startup requires the database but not caught-up projections")
  func startup() async {
    let catchingUp = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/startupz",
      startupProbe: {},
      readinessProbe: { throw WorkerReadinessError.ingestionFreshnessUnhealthy }
    )
    #expect(catchingUp.status == .ok)

    let ready = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      startupProbe: { throw ProbeError.unavailable },
      readinessProbe: {}
    )
    #expect(ready.status == .ok)

    let databaseUnavailable = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/startupz",
      startupProbe: { throw ProbeError.unavailable },
      readinessProbe: {}
    )
    #expect(databaseUnavailable.status == .serviceUnavailable)
    #expect(databaseUnavailable.failedProbe == "startup")
    #expect(databaseUnavailable.failureCategory == String(reflecting: ProbeError.self))
  }

  @Test("readiness requires a successful database probe")
  func readiness() async {
    let ready = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      startupProbe: {},
      readinessProbe: {}
    )
    #expect(ready.status == .ok)

    let unavailable = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      startupProbe: {},
      readinessProbe: { throw ProbeError.unavailable }
    )
    #expect(unavailable.status == .serviceUnavailable)
    #expect(unavailable.failedProbe == "readiness")
    #expect(unavailable.failureCategory == String(reflecting: ProbeError.self))

    let categorizedFailures: [(WorkerReadinessError, String)] = [
      (.missingIngestionHeartbeat, "missing_ingestion_heartbeat"),
      (.staleIngestionHeartbeat, "stale_ingestion_heartbeat"),
      (.ingestionTransportUnhealthy, "ingestion_transport_unhealthy"),
      (.ingestionFreshnessUnhealthy, "ingestion_freshness_unhealthy"),
      (.ingestionCompletenessUnhealthy, "ingestion_completeness_unhealthy"),
    ]
    for (error, expectedCategory) in categorizedFailures {
      let categorized = await WorkerHealthResponseBuilder.response(
        method: .GET,
        uri: "/readyz",
        startupProbe: {},
        readinessProbe: { throw error }
      )
      #expect(categorized.failedProbe == "readiness")
      #expect(categorized.failureCategory == expectedCategory)
    }
  }

  @Test("readiness rejects stale or unhealthy ingestion evidence")
  func ingestionEvidence() async throws {
    let now = Date()
    await #expect(throws: WorkerReadinessError.missingIngestionHeartbeat) {
      try await WorkerReadinessProbe(databaseProbe: {}).run()
    }

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
    await #expect(throws: WorkerReadinessError.ingestionTransportUnhealthy) {
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
    await #expect(throws: WorkerReadinessError.ingestionFreshnessUnhealthy) {
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
    await #expect(throws: WorkerReadinessError.ingestionCompletenessUnhealthy) {
      try await WorkerReadinessProbe(
        databaseProbe: {},
        serviceStateProbe: { incompleteProjection },
        now: { now }
      ).run()
    }
  }

  @Test("legacy Jetstream readiness does not require inapplicable projection repair evidence")
  func legacyJetstreamReadiness() async throws {
    let now = Date()
    let state = serviceState(
      heartbeatAt: now,
      readiness: .healthy,
      freshness: .unknown,
      completeness: .unknown,
      dependencyState: ["ingestion_source": "jetstream"]
    )

    try await WorkerReadinessProbe(
      databaseProbe: {},
      serviceStateProbe: { state },
      now: { now }
    ).run()
  }

  private func serviceState(
    heartbeatAt: Date,
    readiness: OperationsHealthState,
    freshness: OperationsHealthState = .healthy,
    completeness: OperationsHealthState = .healthy,
    dependencyState: [String: String] = [:]
  ) -> OperationsServiceState {
    OperationsServiceState(
      service: "appview-worker",
      environment: "dev",
      instanceId: "worker-1",
      liveness: readiness,
      readiness: readiness,
      freshness: freshness,
      completeness: completeness,
      dependencyState: dependencyState,
      startedAt: heartbeatAt.addingTimeInterval(-60),
      heartbeatAt: heartbeatAt
    )
  }
}

private enum ProbeError: Error {
  case unavailable
}
