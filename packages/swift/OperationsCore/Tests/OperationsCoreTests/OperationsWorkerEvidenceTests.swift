import Foundation
import Logging
import Testing
@testable import OperationsCore

@Suite("Consolidated worker evidence")
struct OperationsWorkerEvidenceTests {
  @Test("Roles are independent; standby and stale owners cannot borrow a legacy heartbeat")
  func roleSelection() {
    let now = Date()
    let legacy = state("appview-worker", at: now)
    let projection = state("projection-pool-appview", at: now)
    let active = state("coordinator-appview", at: now, active: true)
    let standby = state("coordinator-appview", at: now)
    #expect(OperationsWorkerEvidence.ingestion([projection, active], at: now)?.service == projection.service)
    #expect(OperationsWorkerEvidence.recovery([projection], at: now) == nil)
    #expect(OperationsWorkerEvidence.ingestion([active], at: now) == nil)
    #expect(OperationsWorkerEvidence.recovery([active], at: now)?.service == active.service)
    #expect(OperationsWorkerEvidence.recovery([legacy, standby], at: now) == nil)
    #expect(OperationsWorkerEvidence.recovery([legacy, state("coordinator-appview", at: now.addingTimeInterval(-16), active: true)], at: now) == nil)
    #expect(OperationsWorkerEvidence.recovery([legacy], at: now)?.service == legacy.service)
    #expect(OperationsWorkerEvidence.ingestion([legacy], at: now)?.service == legacy.service)
    #expect(OperationsWorkerEvidence.ingestion([state("projection-pool-appview", at: now.addingTimeInterval(2))], at: now) == nil)
  }

  @Test("Complete worker evidence requires both consolidated roles during handoff")
  func requiredCoverage() {
    let now = Date()
    let projection = state("projection-pool-appview", at: now)
    let active = state("coordinator-appview", at: now, active: true)
    let complete = OperationsEvidenceResolver.services(
      [projection, active], requiredServices: ["appview-worker"], at: now)
    #expect(complete.coverage == 1)
    #expect(complete.accuracy == .exact)
    let partial = OperationsEvidenceResolver.services(
      [projection, state("appview-worker", at: now)], requiredServices: ["appview-worker"], at: now)
    #expect(partial.coverage == 0)
  }

  @Test("SQLite verifies coordinator heartbeat identity against current durable ownership")
  func sqliteOwnerValidation() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("worker-evidence-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let store = try SQLiteOperationsStore(path: path.path, environment: "dev", logger: Logger(label: "worker.evidence.tests"))
    let now = Date()
    let role = "indexing.appview-coordinator"
    let lease = try #require(try await store.acquireRoleLease(role: role, ownerID: "owner", leaseUntil: now.addingTimeInterval(30), at: now))
    let evidence = OperationsServiceState(
      service: "coordinator-appview", environment: "dev", instanceId: "replica",
      liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
      dependencyState: ["coordinator_role": role, "coordinator_owner_id": "owner", "coordinator_fencing_token": String(lease.fencingToken)],
      startedAt: now, heartbeatAt: now)
    try await store.upsertServiceState(evidence)
    #expect(OperationsWorkerEvidence.recovery(try await store.listServiceStates(), at: Date()) != nil)
    try await store.releaseRoleLease(role: role, ownerID: "owner", fencingToken: lease.fencingToken, at: Date())
    #expect(OperationsWorkerEvidence.recovery(try await store.listServiceStates(), at: Date()) == nil)
    _ = try await store.acquireRoleLease(role: role, ownerID: "successor", leaseUntil: Date().addingTimeInterval(30), at: Date())
    #expect(OperationsWorkerEvidence.recovery(try await store.listServiceStates(), at: Date()) == nil)
  }

  private func state(_ service: String, at: Date, active: Bool = false) -> OperationsServiceState {
    OperationsServiceState(
      service: service, environment: "dev", instanceId: service,
      liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
      dependencyState: ["coordinator_role": "indexing.appview-coordinator", "coordinator_authority": active ? "active" : "inactive"],
      startedAt: at, heartbeatAt: at)
  }
}
