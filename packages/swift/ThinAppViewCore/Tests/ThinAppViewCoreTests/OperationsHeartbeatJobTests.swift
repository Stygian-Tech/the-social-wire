import Foundation
@preconcurrency import GRDB
import Logging
import OperationsCore
import Testing

@testable import ThinAppViewCore

@Suite("Operations heartbeat evidence")
struct OperationsHeartbeatJobTests {





  @Test("missing service-specific probe publishes Unknown, never Healthy")
  func missingProbeIsUnknown() async throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let job = fixture.job()

    try await job.runOnce(startedAt: now.addingTimeInterval(-60), at: now)

    let state = try #require(
      try await fixture.store.listServiceStates().first { $0.service == "appview" }
    )
    #expect(state.liveness == .unknown)
    #expect(state.readiness == .unknown)
    #expect(state.freshness == .unknown)
    #expect(state.completeness == .unknown)
    #expect(state.dependencyState["operations_database"] == "ready")
    #expect(state.dependencyState["service_probe"] == "missing")
  }

  @Test("fresh service-specific probe can publish Healthy")
  func freshProbeIsHealthy() async throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let job = fixture.job {
      OperationsServiceProbeResult(
        liveness: .healthy,
        readiness: .healthy,
        freshness: .healthy,
        completeness: .healthy,
        dependencyState: ["appview_database": "ready"],
        observedAt: now.addingTimeInterval(-1),
        validUntil: now.addingTimeInterval(30)
      )
    }

    try await job.runOnce(startedAt: now.addingTimeInterval(-60), at: now)

    let state = try #require(
      try await fixture.store.listServiceStates().first { $0.service == "appview" }
    )
    #expect(state.liveness == .healthy)
    #expect(state.readiness == .healthy)
    #expect(state.freshness == .healthy)
    #expect(state.completeness == .healthy)
    #expect(state.dependencyState["service_probe"] == "ready")
  }

  @Test("live clock validates probe evidence after the async probe completes")
  func liveClockDoesNotRejectFreshProbeAsFuture() async throws {
    let fixture = try Fixture()
    let job = fixture.job {
      let observedAt = Date()
      return OperationsServiceProbeResult(
        liveness: .healthy,
        readiness: .healthy,
        freshness: .healthy,
        completeness: .healthy,
        dependencyState: ["appview_database": "ready"],
        observedAt: observedAt,
        validUntil: observedAt.addingTimeInterval(1)
      )
    }

    try await job.runOnce(startedAt: Date(), now: { Date() })

    let state = try #require(try await fixture.store.listServiceStates().first)
    #expect(state.liveness == .healthy)
    #expect(state.readiness == .healthy)
    #expect(state.dependencyState["service_probe"] == "ready")
  }

  @Test("expired probe evidence becomes Unknown")
  func expiredProbeIsUnknown() async throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let job = fixture.job {
      OperationsServiceProbeResult(
        liveness: .healthy,
        readiness: .healthy,
        freshness: .healthy,
        completeness: .healthy,
        dependencyState: ["appview_database": "ready"],
        observedAt: now.addingTimeInterval(-120),
        validUntil: now.addingTimeInterval(-1)
      )
    }

    try await job.runOnce(startedAt: now.addingTimeInterval(-60), at: now)

    let state = try #require(try await fixture.store.listServiceStates().first)
    #expect(state.liveness == .unknown)
    #expect(state.readiness == .unknown)
    #expect(state.freshness == .unknown)
    #expect(state.dependencyState["service_probe"] == "expired")
  }

  @Test("failed probe publishes Degraded without leaking the error message")
  func failedProbeIsDegraded() async throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let job = fixture.job {
      throw ProbeFailure.secret("database password")
    }

    try await job.runOnce(startedAt: now.addingTimeInterval(-60), at: now)

    let state = try #require(try await fixture.store.listServiceStates().first)
    #expect(state.liveness == .degraded)
    #expect(state.readiness == .degraded)
    #expect(state.freshness == .unknown)
    #expect(state.dependencyState["service_probe"]?.hasPrefix("failed:") == true)
    #expect(state.dependencyState["service_probe"]?.contains("password") == false)
  }

  @Test("telemetry snapshot publishes exact exporter evidence")
  func telemetrySnapshotEvidence() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let lastExport = now.addingTimeInterval(-12.25)
    let evidence = OperationsHeartbeatJob.telemetryEvidence(
      OperationsTelemetryBufferSnapshot(
        queueDepth: 3,
        inFlightCount: 2,
        capacity: 10,
        droppedCount: 0,
        consecutiveFailures: 0,
        lastSuccessfulExportAt: lastExport
      ),
      at: now
    )

    #expect(evidence.dependencyState["telemetry_queue_depth"] == "3")
    #expect(evidence.dependencyState["telemetry_in_flight"] == "2")
    #expect(evidence.dependencyState["telemetry_queue_capacity"] == "10")
    #expect(evidence.dependencyState["telemetry_dropped_total"] == "0")
    #expect(evidence.dependencyState["telemetry_consecutive_failures"] == "0")
    #expect(evidence.dependencyState["telemetry_last_export_age_seconds"] == "12.250")
    #expect(evidence.dependencyState["telemetry_exporter"] == "exporting")
    #expect(evidence.dependencyState["telemetry_last_successful_export_at"] != "none")
    #expect(!evidence.exportFailureObserved)
    #expect(!evidence.dropObserved)
    #expect(!evidence.freshnessUncertain)
    #expect(!evidence.completenessUncertain)
  }

  @Test("invalid telemetry snapshot cannot publish healthy freshness")
  func invalidTelemetrySnapshotIsUnknown() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let evidence = OperationsHeartbeatJob.telemetryEvidence(
      OperationsTelemetryBufferSnapshot(
        queueDepth: 2,
        inFlightCount: 0,
        capacity: 1,
        droppedCount: 0,
        consecutiveFailures: 0,
        lastSuccessfulExportAt: now.addingTimeInterval(1)
      ),
      at: now
    )

    #expect(evidence.dependencyState["telemetry_exporter"] == "unknown_invalid_snapshot")
    #expect(evidence.dependencyState["telemetry_last_export_age_seconds"] == "invalid_future")
    #expect(evidence.freshnessUncertain)
    #expect(evidence.completenessUncertain)
  }

  @Test("observed telemetry failures and drops lower heartbeat trust")
  func telemetryLossDegradesHeartbeat() async throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let telemetry = OperationsTelemetryBuffer(
      capacity: 1,
      batchSize: 1,
      maxRetryAttempts: 1,
      logger: Logger(label: "heartbeat.telemetry.test"),
      exporter: { _ in throw ProbeFailure.secret("export password") }
    )
    #expect(await telemetry.enqueue(.metric(.init(name: "heartbeat.test", value: 1, dimensions: [:]))))
    #expect(
      !(await telemetry.enqueue(.metric(.init(name: "heartbeat.test", value: 2, dimensions: [:]))))
    )
    #expect(await telemetry.flushOnce() == 0)
    let job = fixture.job(telemetry: telemetry) {
      OperationsServiceProbeResult(
        liveness: .healthy,
        readiness: .healthy,
        freshness: .healthy,
        completeness: .healthy,
        dependencyState: ["appview_database": "ready"],
        observedAt: now.addingTimeInterval(-1),
        validUntil: now.addingTimeInterval(30)
      )
    }

    try await job.runOnce(startedAt: now.addingTimeInterval(-60), at: now)

    let state = try #require(try await fixture.store.listServiceStates().first)
    #expect(state.freshness == .degraded)
    #expect(state.completeness == .degraded)
    #expect(state.dependencyState["telemetry_exporter"] == "degraded")
    #expect(state.dependencyState["telemetry_queue_depth"] == "0")
    #expect(state.dependencyState["telemetry_in_flight"] == "0")
    #expect(state.dependencyState["telemetry_queue_capacity"] == "1")
    #expect(state.dependencyState["telemetry_dropped_total"] == "2")
    #expect(state.dependencyState["telemetry_consecutive_failures"] == "1")
    #expect(state.dependencyState["telemetry_last_successful_export_at"] == "none")
    #expect(state.dependencyState["telemetry_last_export_age_seconds"] == "unknown")
  }

  @Test("historical telemetry loss requires explicit valid successful-drain evidence")
  func telemetryRecoveryEvidence() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func evidence(drop: Date?, recovery: Date?, success: Date? = nil,
                  queued: Int = 0, failures: Int = 0) -> OperationsTelemetryHeartbeatEvidence {
      OperationsHeartbeatJob.telemetryEvidence(.init(
        queueDepth: queued, inFlightCount: 0, capacity: 10, droppedCount: 4,
        consecutiveFailures: failures, lastSuccessfulExportAt: success ?? now.addingTimeInterval(-1),
        lastDropAt: drop, lastDropRecoveredAt: recovery), at: now)
    }
    let drop = now.addingTimeInterval(-10)
    let recovery = now.addingTimeInterval(-5)
    let recovered = evidence(drop: drop, recovery: recovery)
    #expect(!recovered.dropObserved)
    #expect(recovered.dependencyState["telemetry_loss_state"] == "recovered")
    #expect(recovered.dependencyState["telemetry_dropped_total"] == "4")
    #expect(recovered.dependencyState["telemetry_exporter"] == "idle")
    let queued = evidence(drop: drop, recovery: recovery, queued: 2)
    #expect(!queued.dropObserved)
    #expect(queued.dependencyState["telemetry_exporter"] == "queued")
    #expect(evidence(drop: drop, recovery: recovery, failures: 1).exportFailureObserved)
    #expect(evidence(drop: drop, recovery: nil).dropObserved)
    #expect(evidence(drop: nil, recovery: nil).dropObserved)
    for invalid in [
      evidence(drop: nil, recovery: recovery),
      evidence(drop: recovery, recovery: drop),
      evidence(drop: drop, recovery: drop),
      evidence(drop: drop, recovery: now.addingTimeInterval(1)),
      evidence(drop: now.addingTimeInterval(1), recovery: nil),
      evidence(drop: drop, recovery: recovery, success: drop),
    ] {
      #expect(invalid.completenessUncertain)
      #expect(invalid.freshnessUncertain)
      #expect(invalid.dependencyState["telemetry_exporter"] == "unknown_invalid_snapshot")
    }
  }

  @Test("recovered telemetry never upgrades unhealthy or unavailable ingestion evidence")
  func telemetryRecoveryPreservesIngestionHealth() async throws {
    let fixture = try Fixture()
    let telemetry = OperationsTelemetryBuffer(
      capacity: 4, logger: Logger(label: "heartbeat.telemetry.recovery"), exporter: { _ in })
    for value in 0..<4 {
      #expect(await telemetry.enqueue(.metric(.init(name: "test", value: Double(value), dimensions: [:]))))
    }
    #expect(!(await telemetry.enqueue(.metric(.init(name: "test", value: 5, dimensions: [:])))))
    #expect(await telemetry.flushOnce() == 4)
    #expect(await telemetry.snapshot().lastDropRecoveredAt != nil)
    for health in [OperationsHealthState.healthy, .degraded, .unhealthy, .unknown] {
      let now = Date()
      let job = fixture.job(telemetry: telemetry) {
        .init(liveness: .healthy, readiness: .healthy, freshness: health, completeness: health,
              dependencyState: ["appview_database": "ready"], observedAt: now, validUntil: now.addingTimeInterval(30))
      }
      try await job.runOnce(startedAt: now.addingTimeInterval(-60), at: now)
      let state = try #require(try await fixture.store.listServiceStates().first)
      #expect(state.freshness == health)
      #expect(state.completeness == health)
      #expect(state.dependencyState["telemetry_loss_state"] == "recovered")
      #expect(state.dependencyState["telemetry_dropped_total"] == "1")
      #expect(await telemetry.flushOnce() == 4)
    }
  }

  @Test("heartbeat emits bounded samples for all health dimensions")
  func heartbeatEmitsHealthSamples() async throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = HealthTelemetryRecorder()
    let telemetry = OperationsTelemetryBuffer(
      capacity: 10,
      batchSize: 10,
      logger: Logger(label: "heartbeat.health-samples.test")
    ) { signals in
      await recorder.append(signals)
    }
    let job = fixture.job(telemetry: telemetry) {
      OperationsServiceProbeResult(
        liveness: .healthy,
        readiness: .degraded,
        freshness: .unhealthy,
        completeness: .unknown,
        dependencyState: ["appview_database": "ready"],
        observedAt: now.addingTimeInterval(-1),
        validUntil: now.addingTimeInterval(30)
      )
    }

    try await job.runOnce(startedAt: now.addingTimeInterval(-60), at: now)
    #expect(await telemetry.flushOnce() == 4)

    let samples = await recorder.metrics(named: "socialwire.service.health.samples_total")
    #expect(samples.count == 4)
    #expect(Set(samples.compactMap { $0.dimensions["service"] }) == ["appview"])
    #expect(Set(samples.compactMap { $0.dimensions["dimension"] }) == [
      "liveness", "readiness", "freshness", "completeness",
    ])
    #expect(Set(samples.compactMap { $0.dimensions["state"] }) == [
      "healthy", "degraded", "unhealthy", "unknown",
    ])
    #expect(samples.allSatisfy { $0.value == 1 })
    #expect(samples.allSatisfy { $0.dimensions["instance_id"] == nil })
  }

  @Test("Coordinator health history requires validated active-owner evidence")
  func coordinatorHealthHistory() async throws {
    let fixture = try Fixture()
    let now = Date()
    let role = "indexing.appview-coordinator"
    let lease = try #require(try await fixture.store.acquireRoleLease(
      role: role, ownerID: "owner", leaseUntil: now.addingTimeInterval(30), at: now))
    let recorder = HealthTelemetryRecorder()
    let telemetry = OperationsTelemetryBuffer(capacity: 10, batchSize: 10,
      logger: Logger(label: "heartbeat.owner.samples")) { await recorder.append($0) }
    let job = OperationsHeartbeatJob(
      store: fixture.store, service: "coordinator-appview", environment: "test", instanceId: "owner",
      dependencyProbe: {
        OperationsServiceProbeResult(liveness: .healthy, readiness: .healthy, freshness: .healthy,
          completeness: .healthy, dependencyState: [
            "appview_database": "ready", "coordinator_role": role, "coordinator_owner_id": "owner",
            "coordinator_fencing_token": String(lease.fencingToken),
          ], requiredDependencyKeys: ["appview_database"], observedAt: now, validUntil: now.addingTimeInterval(30))
      }, telemetry: telemetry, logger: Logger(label: "heartbeat.owner"))
    try await job.runOnce(startedAt: now, at: now)
    #expect(await telemetry.flushOnce() == 4)
    let samples = await recorder.metrics(named: "socialwire.service.health.samples_total")
    #expect(samples.allSatisfy {
      $0.dimensions["coordinator_authority"] == "active" && $0.dimensions["coordinator_role"] == role
    })
    #expect(samples.allSatisfy { $0.dimensions["coordinator_owner_id"] == nil })
    try await fixture.store.releaseRoleLease(role: role, ownerID: "owner", fencingToken: lease.fencingToken, at: Date())
    try await job.runOnce(startedAt: now, at: Date())
    #expect(await telemetry.flushOnce() == 0)
  }

  private enum ProbeFailure: Error {
    case secret(String)
  }

  private struct Fixture {
    let store: SQLiteOperationsStore
    let path: String

    init() throws {
      path = FileManager.default.temporaryDirectory
        .appendingPathComponent("heartbeat-\(UUID().uuidString).sqlite")
        .path
      store = try SQLiteOperationsStore(
        path: path,
        environment: "test",
        logger: Logger(label: "heartbeat.store")
      )
    }

    func job(
      telemetry: OperationsTelemetryBuffer? = nil,
      dependencyProbe: OperationsServiceDependencyProbe? = nil
    ) -> OperationsHeartbeatJob {
      OperationsHeartbeatJob(
        store: store,
        service: "appview",
        environment: "test",
        instanceId: "test",
        dependencyProbe: dependencyProbe,
        telemetry: telemetry,
        logger: Logger(label: "heartbeat.test")
      )
    }
  }
}

private actor HealthTelemetryRecorder {
  private var signals: [OperationsTelemetrySignal] = []

  func append(_ newSignals: [OperationsTelemetrySignal]) {
    signals.append(contentsOf: newSignals)
  }

  func metrics(named name: String) -> [OperationsMetricSample] {
    signals.compactMap { signal in
      guard case .metric(let sample) = signal, sample.name == name else { return nil }
      return sample
    }
  }
}
