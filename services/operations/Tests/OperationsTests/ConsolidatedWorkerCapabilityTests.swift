import Foundation
import Logging
import OperationsCore
import Testing
@testable import Operations

@Test("Consolidated projection supplies authority alerts while only the active coordinator supplies recovery")
func consolidatedWorkerCapabilities() async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("consolidated-capabilities-\(UUID()).sqlite")
  defer { try? FileManager.default.removeItem(at: path) }
  let logger = Logger(label: "consolidated.evidence.tests")
  let store = try SQLiteOperationsStore(path: path.path, environment: "dev", logger: logger)
  let config = OperationsConfiguration.fromEnvironment([
    "APP_ENV": "dev", "OPERATIONS_RECOVERY_ENABLED": "true",
    "OPERATIONS_BACKFILL_FINGERPRINT_SECRET": "test-secret",
  ])
  let now = Date()
  let resolver = OperationsCapabilityResolver(store: store, config: config)
  let base: [String: String] = [
    "operations_database": "ready", "appview_database": "ready",
    "ingestion_authority": "jetstream_v2_inbox", "jetstream_v2_source_generation": "west-v2",
    "jetstream_replay": "enabled_durable_v2", "pds_reconciliation": "enabled_diagnostic_only",
  ]
  func state(_ service: String, dependencies: [String: String]) -> OperationsServiceState {
    OperationsServiceState(service: service, environment: "dev", instanceId: service,
      liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
      dependencyState: dependencies, startedAt: now, heartbeatAt: now)
  }
  try await store.upsertServiceState(state("projection-pool-appview", dependencies: base))
  #expect(!(await resolver.resolve(at: now)).recovery.enabled)
  let evaluator = AlertEvaluator(store: store, config: config, logger: logger, webhook: nil)
  try await evaluator.evaluate(at: now)
  let alerts = try await store.listAlerts(view: .active, limit: 100, before: nil).items
  #expect(!alerts.contains { $0.conditionKey == "ingestion:authority_evidence_missing" })

  // A legacy heartbeat remains compatible until consolidated coordinator evidence appears.
  try await store.upsertServiceState(state("appview-worker", dependencies: base))
  #expect((await resolver.resolve(at: now)).recovery.enabled)
  try await store.upsertServiceState(state("coordinator-appview", dependencies: base))
  #expect(!(await resolver.resolve(at: now)).recovery.enabled)
  let role = "indexing.appview-coordinator"
  let lease = try #require(try await store.acquireRoleLease(role: role, ownerID: "owner",
    leaseUntil: now.addingTimeInterval(30), at: now))
  var owned = base
  owned["coordinator_role"] = role
  owned["coordinator_owner_id"] = "owner"
  owned["coordinator_fencing_token"] = String(lease.fencingToken)
  try await store.upsertServiceState(state("coordinator-appview", dependencies: owned))
  let active = await resolver.resolve(at: now)
  #expect(active.recovery.enabled)
  #expect(active.recoveryModes.jetstreamReplay.enabled)
  #expect(active.recoveryModes.pdsReconciliation.enabled)
  try await store.releaseRoleLease(role: role, ownerID: "owner", fencingToken: lease.fencingToken, at: Date())
  #expect(!(await resolver.resolve(at: now)).recovery.enabled)
}
