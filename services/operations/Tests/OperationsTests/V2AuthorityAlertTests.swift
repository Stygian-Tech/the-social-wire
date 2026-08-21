import Foundation
import Logging
import OperationsCore
import Testing

@testable import Operations

@Test("durable V2 authority replaces legacy Jetstream transport alerts")
func durableV2AuthorityReplacesLegacyTransportAlerts() async throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("operations-v2-authority-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: url) }
  let store = try SQLiteOperationsStore(
    path: url.path,
    environment: "dev",
    logger: Logger(label: "operations.v2-authority.test")
  )
  let config = OperationsConfiguration.fromEnvironment(["APP_ENV": "dev"])
  let evaluator = AlertEvaluator(
    store: store,
    config: config,
    logger: Logger(label: "operations.v2-authority.test"),
    webhook: nil
  )
  let now = Date()

  try await store.upsertServiceState(authorityWorker(source: "jetstream", at: now))
  try await evaluator.evaluate(at: now)
  #expect(try await activeAlertKeys(store).contains("jetstream:transport_evidence_missing"))
  #expect(try await activeAlertKeys(store).contains("jetstream:queue_evidence_missing"))

  let switchedAt = now.addingTimeInterval(1)
  try await store.upsertServiceState(
    authorityWorker(
      source: OperationsEvidenceResolver.durableJetstreamV2AuthoritySource,
      generation: "west-v2",
      at: switchedAt
    )
  )
  try await evaluator.evaluate(at: switchedAt)

  let switchedKeys = try await activeAlertKeys(store)
  #expect(!switchedKeys.contains("ingestion:authority_evidence_missing"))
  #expect(!switchedKeys.contains { $0.hasPrefix("jetstream:") })
  #expect(switchedKeys.contains("jetstream_v2_inbox:transport_evidence_missing"))

  try await evaluator.evaluateDurableV2Transport(
    checkpoint: authorityCheckpoint(updatedAt: switchedAt),
    at: switchedAt
  )
  let healthyKeys = try await activeAlertKeys(store)
  #expect(!healthyKeys.contains { $0.hasPrefix("jetstream_v2_inbox:") })

  try await evaluator.evaluateDurableV2Transport(
    checkpoint: authorityCheckpoint(
      updatedAt: switchedAt,
      intakeHeartbeatAt: switchedAt.addingTimeInterval(-301)
    ),
    at: switchedAt
  )
  let expired = try #require(
    try await activeAlerts(store).first {
      $0.conditionKey == "jetstream_v2_inbox:transport_heartbeat_expired"
    }
  )
  #expect(expired.evidence["checkpoint_updated_at"] == switchedAt.ISO8601Format())
  #expect(
    expired.evidence["observedAt"]
      == switchedAt.addingTimeInterval(-301).ISO8601Format()
  )

  try await evaluator.evaluateDurableV2Transport(
    checkpoint: authorityCheckpoint(updatedAt: switchedAt, replayState: .failed),
    at: switchedAt
  )
  #expect(try await activeAlertKeys(store).contains("jetstream_v2_inbox:replay_failed"))

  try await evaluator.evaluateDurableV2Transport(
    checkpoint: authorityCheckpoint(
      updatedAt: switchedAt.addingTimeInterval(-3_600),
      replayState: .snapshotComplete,
      includeIntakeHeartbeat: false
    ),
    at: switchedAt
  )
  #expect(try await activeAlertKeys(store).allSatisfy { !$0.hasPrefix("jetstream_v2_inbox:") })
}

@Test("durable V2 actionable backlog alert follows worker freshness thresholds")
func durableV2BacklogAlertFollowsWorkerThresholds() async throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("operations-v2-backlog-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: url) }
  let store = try SQLiteOperationsStore(
    path: url.path,
    environment: "dev",
    logger: Logger(label: "operations.v2-backlog.test")
  )
  let evaluator = AlertEvaluator(
    store: store,
    config: OperationsConfiguration.fromEnvironment(["APP_ENV": "dev"]),
    logger: Logger(label: "operations.v2-backlog.test"),
    webhook: nil
  )
  let now = Date()
  let checkpoint = authorityCheckpoint(updatedAt: now)

  try await evaluator.evaluateDurableV2Backlog(
    inbox: durabilitySnapshot(oldestAge: 61, at: now).inbox,
    observedAt: now,
    checkpoint: checkpoint,
    at: now
  )
  let warning = try #require(
    try await activeAlerts(store).first {
      $0.conditionKey == "jetstream_v2_inbox:actionable_backlog_overdue"
    }
  )
  #expect(warning.severity == "warning")
  #expect(warning.evidence["oldest_actionable_age_seconds"] == "61.0")
  #expect(warning.evidence["threshold_seconds"] == "60.0")
  #expect(warning.evidence["cursor_delta"] == nil)

  try await evaluator.evaluateDurableV2Backlog(
    inbox: durabilitySnapshot(oldestAge: 901, at: now.addingTimeInterval(1)).inbox,
    observedAt: now.addingTimeInterval(1),
    checkpoint: checkpoint,
    at: now.addingTimeInterval(1)
  )
  let critical = try #require(
    try await activeAlerts(store).first {
      $0.conditionKey == "jetstream_v2_inbox:actionable_backlog_overdue"
    }
  )
  #expect(critical.id == warning.id)
  #expect(critical.severity == "critical")
  #expect(critical.evidence["threshold_seconds"] == "900.0")

  try await evaluator.evaluateDurableV2Backlog(
    inbox: durabilitySnapshot(oldestAge: 60, at: now.addingTimeInterval(2)).inbox,
    observedAt: now.addingTimeInterval(2),
    checkpoint: checkpoint,
    at: now.addingTimeInterval(2)
  )
  #expect(
    try await activeAlerts(store).allSatisfy {
      $0.conditionKey != "jetstream_v2_inbox:actionable_backlog_overdue"
    }
  )

  try await evaluator.evaluateDurableV2Backlog(
    inbox: durabilitySnapshot(oldestAge: 61, at: now.addingTimeInterval(3)).inbox,
    observedAt: now.addingTimeInterval(3),
    checkpoint: checkpoint,
    at: now.addingTimeInterval(3)
  )
  try await store.upsertServiceState(authorityWorker(source: "jetstream", at: now.addingTimeInterval(4)))
  try await evaluator.evaluate(at: now.addingTimeInterval(4))
  #expect(
    try await activeAlerts(store).allSatisfy {
      $0.conditionKey != "jetstream_v2_inbox:actionable_backlog_overdue"
    }
  )
}

private func activeAlertKeys(_ store: SQLiteOperationsStore) async throws -> Set<String> {
  Set(try await activeAlerts(store).map(\.conditionKey))
}

private func activeAlerts(_ store: SQLiteOperationsStore) async throws -> [OperationsAlert] {
  try await store.listAlerts(view: .active, limit: 250, before: nil).items
}

private func authorityWorker(
  source: String,
  generation: String? = nil,
  at now: Date
) -> OperationsServiceState {
  var dependencies = ["ingestion_authority": source]
  if let generation {
    dependencies["jetstream_v2_source_generation"] = generation
  }
  return OperationsServiceState(
    service: "appview-worker",
    environment: "dev",
    instanceId: "worker-1",
    liveness: .healthy,
    readiness: .healthy,
    freshness: .healthy,
    completeness: .healthy,
    dependencyState: dependencies,
    startedAt: now.addingTimeInterval(-60),
    heartbeatAt: now
  )
}

private func authorityCheckpoint(
  updatedAt: Date,
  intakeHeartbeatAt: Date? = nil,
  replayState: JetstreamReplayState = .live,
  includeIntakeHeartbeat: Bool = true
) -> JetstreamDurabilityCheckpoint {
  JetstreamDurabilityCheckpoint(
    environment: "dev",
    sourceGeneration: "west-v2",
    sourceHost: "jetstream.us-west.bsky.network",
    streamNSID: "network.bsky.jetstream.subscribeEvents",
    filterFingerprint: "filter-v1",
    cursorKind: .jetstreamV2Sequence,
    lastStagedSequence: 200,
    lastStagedEventAt: updatedAt,
    lastStagedAt: updatedAt,
    lastAppliedSequence: 190,
    lastAppliedEventAt: updatedAt,
    lastAppliedAt: updatedAt,
    replayState: replayState,
    replayAfterSequence: replayState == .snapshotComplete ? 100 : nil,
    replayBeforeSequence: replayState == .snapshotComplete ? 200 : nil,
    replaySealedSequence: replayState == .snapshotComplete ? 200 : nil,
    intakeHeartbeatAt: includeIntakeHeartbeat ? (intakeHeartbeatAt ?? updatedAt) : nil,
    updatedAt: updatedAt
  )
}

private func durabilitySnapshot(oldestAge: Double, at now: Date) -> IngestionDurabilitySnapshot {
  IngestionDurabilitySnapshot(
    environment: "dev",
    checkpoints: [authorityCheckpoint(updatedAt: now)],
    inbox: IngestionInboxMetrics(
      pending: 2,
      leased: 1,
      retrying: 1,
      total: 4,
      oldestPendingAt: now.addingTimeInterval(-oldestAge),
      oldestPendingAgeSeconds: oldestAge
    ),
    generatedAt: now
  )
}
