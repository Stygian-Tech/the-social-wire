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

  @Test("V2 readiness failures carry bounded generation-scoped log diagnostics")
  func v2ReadinessFailureDiagnostics() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let state = serviceState(
      heartbeatAt: now.addingTimeInterval(-3),
      readiness: .healthy,
      freshness: .degraded,
      dependencyState: [
        "ingestion_source": "jetstream_v2_inbox",
        "jetstream_v2_source_generation": "jetstream-v2-us-west-v1",
        "jetstream_v2_replay_state": "live",
        "jetstream_v2_intake_heartbeat_age_seconds": "5",
        "jetstream_v2_inbox_pending": "11",
        "jetstream_v2_inbox_leased": "7",
        "jetstream_v2_inbox_retrying": "3",
        "jetstream_v2_dead_letters": "2",
        "jetstream_v2_inbox_oldest_actionable_age_seconds": "901",
        "jetstream_v2_checkpoint_age_seconds": "12",
      ]
    )

    let failure: WorkerReadinessFailure
    do {
      try await WorkerReadinessProbe(
        databaseProbe: {},
        serviceStateProbe: { state },
        now: { now }
      ).run(includingDiagnostics: true)
      Issue.record("Expected V2 freshness failure")
      return
    } catch let caught as WorkerReadinessFailure {
      failure = caught
    }

    #expect(failure.reason == .ingestionFreshnessUnhealthy)
    #expect(failure.diagnostics.logMetadata == [
      "v2_source_generation": "jetstream-v2-us-west-v1",
      "v2_replay_state": "live",
      "v2_lease_heartbeat_age_seconds": "8",
      "v2_inbox_pending": "11",
      "v2_inbox_leased": "7",
      "v2_inbox_retrying": "3",
      "v2_inbox_dead_letters": "2",
      "v2_oldest_actionable_age_seconds": "904",
      "v2_checkpoint_age_seconds": "15",
    ])

    let response = await WorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      startupProbe: {},
      readinessProbe: { throw failure }
    )
    #expect(response.status == .serviceUnavailable)
    #expect(response.body == #"{"service":"charybdis","status":"unavailable"}"#)
    #expect(response.failureCategory == "ingestion_freshness_unhealthy")
    #expect(response.failureLogFields?["probe"] == "readiness")
    #expect(response.failureLogFields?["reason"] == "ingestion_freshness_unhealthy")
    #expect(response.failureLogFields?["v2_inbox_pending"] == "11")
  }

  @Test("V2 diagnostic mapping rejects unsafe and unbounded dependency values")
  func v2ReadinessDiagnosticsAreSafe() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let state = serviceState(
      heartbeatAt: now,
      readiness: .healthy,
      dependencyState: [
        "ingestion_source": "jetstream_v2_inbox",
        "jetstream_v2_source_generation": "generation\nsecret-token",
        "jetstream_v2_replay_state": "payload-content",
        "jetstream_v2_intake_heartbeat_age_seconds": "inf",
        "jetstream_v2_inbox_pending": "18446744073709551615",
        "jetstream_v2_inbox_leased": "-1",
        "jetstream_v2_inbox_retrying": "not-a-count",
        "jetstream_v2_dead_letters": "2",
        "jetstream_v2_inbox_oldest_actionable_age_seconds": "999999999999",
        "jetstream_v2_checkpoint_age_seconds": "5",
        "viewer_did": "did:plc:must-not-be-logged",
        "payload": "must-not-be-logged",
      ]
    )

    let diagnostics = try #require(WorkerReadinessDiagnostics.v2(from: state, at: now))
    #expect(diagnostics.logMetadata["v2_source_generation"] == "invalid")
    #expect(diagnostics.logMetadata["v2_replay_state"] == "unknown")
    #expect(diagnostics.logMetadata["v2_lease_heartbeat_age_seconds"] == "unknown")
    #expect(diagnostics.logMetadata["v2_inbox_pending"] == "1000000000+")
    #expect(diagnostics.logMetadata["v2_inbox_leased"] == "unknown")
    #expect(diagnostics.logMetadata["v2_inbox_retrying"] == "unknown")
    #expect(diagnostics.logMetadata["v2_oldest_actionable_age_seconds"] == "31536000+")
    #expect(diagnostics.logMetadata.count == 9)
    #expect(!diagnostics.logMetadata.values.contains { $0.contains("did:plc") })
    #expect(!diagnostics.logMetadata.values.contains { $0.contains("must-not-be-logged") })
    #expect(!diagnostics.logMetadata.values.contains { $0.contains("secret-token") })
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
