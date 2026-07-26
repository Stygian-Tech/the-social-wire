import Foundation
import Logging
import OperationsCore
import Testing

@testable import ThinAppViewCore

@Suite("Operations heartbeat evidence")
struct OperationsHeartbeatJobTests {
  @Test("projection backlog fail-closes freshness and completeness")
  func projectionBacklogHealth() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(
      queued: Int = 0,
      running: Int = 0,
      failed: Int = 0,
      oldestAge: TimeInterval? = nil,
      observedAt: Date? = nil
    ) -> AppViewProjectionRepairBacklogSnapshot {
      let observation = observedAt ?? now
      return AppViewProjectionRepairBacklogSnapshot(
        environment: "test",
        queuedCount: queued,
        runningCount: running,
        failedCount: failed,
        oldestActionableAt: oldestAge.map { observation.addingTimeInterval(-$0) },
        oldestActionableAgeSeconds: oldestAge,
        observedAt: observation
      )
    }

    let empty = ThinAppViewWorkerRuntime.projectionRepairHealthEvidence(
      snapshot(), expectedEnvironment: "test", tapMode: .authoritative, at: now)
    #expect(empty.freshness == .healthy)
    #expect(empty.completeness == .healthy)
    #expect(empty.metadata["projection_repair_backlog"] == "ready")
    #expect(empty.metadata["projection_repair_queued_count"] == "0")

    let unverifiedAuthority = ThinAppViewWorkerRuntime.projectionRepairHealthEvidence(
      snapshot(), expectedEnvironment: "test", tapMode: .shadow, at: now)
    #expect(unverifiedAuthority.freshness == .unknown)
    #expect(unverifiedAuthority.completeness == .unknown)
    #expect(unverifiedAuthority.metadata["projection_repair_backlog"] == "not_authoritative")

    let pending = ThinAppViewWorkerRuntime.projectionRepairHealthEvidence(
      snapshot(queued: 1, oldestAge: 2),
      expectedEnvironment: "test",
      tapMode: .authoritative,
      at: now
    )
    #expect(pending.freshness == .degraded)
    #expect(pending.completeness == .degraded)
    #expect(pending.metadata["projection_repair_backlog"] == "pending")

    let overdue = ThinAppViewWorkerRuntime.projectionRepairHealthEvidence(
      snapshot(running: 1, oldestAge: 6),
      expectedEnvironment: "test",
      tapMode: .authoritative,
      at: now
    )
    #expect(overdue.freshness == .unhealthy)
    #expect(overdue.completeness == .unhealthy)
    #expect(overdue.metadata["projection_repair_backlog"] == "overdue")

    let failed = ThinAppViewWorkerRuntime.projectionRepairHealthEvidence(
      snapshot(failed: 1, oldestAge: 1),
      expectedEnvironment: "test",
      tapMode: .authoritative,
      at: now
    )
    #expect(failed.freshness == .unhealthy)
    #expect(failed.completeness == .unhealthy)
    #expect(failed.metadata["projection_repair_backlog"] == "failed")

    let stale = ThinAppViewWorkerRuntime.projectionRepairHealthEvidence(
      snapshot(observedAt: now.addingTimeInterval(-6)),
      expectedEnvironment: "test",
      tapMode: .authoritative,
      at: now
    )
    #expect(stale.freshness == .unknown)
    #expect(stale.completeness == .unknown)
    #expect(stale.metadata["projection_repair_backlog"] == "unknown")
  }

  @Test("worker dependency probe uses durable projection backlog evidence")
  func workerDependencyProbeUsesBacklog() async throws {
    let logger = Logger(label: "worker-probe.test")
    let appViewPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("worker-probe-appview-\(UUID().uuidString).sqlite")
      .path
    let operationsPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("worker-probe-operations-\(UUID().uuidString).sqlite")
      .path
    let appViewStore = try SQLiteThinAppViewStore(path: appViewPath, logger: logger)
    let operationsStore = try SQLiteOperationsStore(
      path: operationsPath,
      environment: "test",
      logger: logger
    )
    let operationsConfig = OperationsConfiguration.fromEnvironment([
      "APP_ENV": "test",
      "FLY_MACHINE_ID": "test-worker",
    ])
    let tapConfig = TapConsumerConfiguration(
      mode: .authoritative,
      environment: "test",
      baseURL: URL(string: "http://127.0.0.1:2480")!,
      channelURL: URL(string: "ws://127.0.0.1:2480/channel")!,
      adminPassword: "test-secret"
    )
    try await operationsStore.markStreamConnected(source: "tap", at: Date())
    let probe = ThinAppViewWorkerRuntime.workerDependencyProbe(
      store: appViewStore,
      operationsStore: operationsStore,
      operationsConfig: operationsConfig,
      tapConfiguration: tapConfig,
      pdsReconciliationAvailable: false
    )

    let empty = try await probe()
    #expect(empty.freshness == .healthy)
    #expect(empty.completeness == .healthy)
    #expect(empty.dependencyState["projection_repair_backlog"] == "ready")

    let old = Date().addingTimeInterval(-10)
    try await appViewStore.applyTapContentMutation(
      .delete(
        uri: "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/site.standard.document/article",
        authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.document"
      ),
      environment: "test",
      eventId: 999,
      repoRev: "rev-999",
      eventTime: old,
      observedAt: old
    )

    let overdue = try await probe()
    #expect(overdue.freshness == .unhealthy)
    #expect(overdue.completeness == .unhealthy)
    #expect(overdue.dependencyState["projection_repair_backlog"] == "overdue")
    #expect(overdue.dependencyState["projection_repair_queued_count"] == "1")
  }

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
