import Foundation
import Testing

@testable import OperationsCore

@Test("durable V2 authority uses its advertised generation checkpoint")
func durableV2AuthorityUsesMatchingCheckpoint() {
  let now = Date(timeIntervalSince1970: 10_000)
  let matching = durabilityCheckpoint(generation: "west-v2", updatedAt: now.addingTimeInterval(-2))
  let other = durabilityCheckpoint(generation: "east-v2", updatedAt: now)
  let resolution = OperationsEvidenceResolver.ingestionAuthority(
    services: [durableV2Worker(generation: "west-v2", at: now)],
    streams: [],
    durability: IngestionDurabilitySnapshot(
      environment: "dev",
      checkpoints: [other, matching],
      inbox: IngestionInboxMetrics(pending: 104, leased: 2, retrying: 1),
      inboxBySourceGeneration: [
        "west-v2": IngestionInboxMetrics(pending: 4, leased: 2, retrying: 1),
        "east-v2": IngestionInboxMetrics(pending: 100),
      ],
      generatedAt: now
    ),
    at: now
  )

  #expect(resolution.source == OperationsEvidenceResolver.durableJetstreamV2AuthoritySource)
  #expect(resolution.state?.source == OperationsEvidenceResolver.durableJetstreamV2AuthoritySource)
  #expect(resolution.state?.connectionState == .connected)
  #expect(resolution.state?.lastReceivedCursor == 200)
  #expect(resolution.state?.lastCommittedCursor == 190)
  #expect(resolution.state?.queueDepth == 7)
  #expect(resolution.state?.queueEvidence?.source == "appview_ingestion_inbox")
  #expect(resolution.durableCheckpoint == matching)
  #expect(resolution.evidence.source == "appview_jetstream_checkpoints")
  #expect(resolution.evidence.accuracy == .exact)
  #expect(resolution.evidence.indexedThrough == matching.updatedAt)
  #expect(resolution.evidence.coverage == 1)
}

@Test("durable V2 authority rejects a checkpoint from another generation")
func durableV2AuthorityRejectsWrongGeneration() {
  let now = Date(timeIntervalSince1970: 10_000)
  let resolution = OperationsEvidenceResolver.ingestionAuthority(
    services: [durableV2Worker(generation: "west-v2", at: now)],
    streams: [],
    durability: IngestionDurabilitySnapshot(
      environment: "dev",
      checkpoints: [durabilityCheckpoint(generation: "east-v2", updatedAt: now)],
      generatedAt: now
    ),
    at: now
  )

  #expect(resolution.source == OperationsEvidenceResolver.durableJetstreamV2AuthoritySource)
  #expect(resolution.durableCheckpoint == nil)
  #expect(resolution.evidence.accuracy == .unavailable)
  #expect(resolution.evidence.coverage == 0)
  #expect(resolution.evidence.degradedReason?.contains("advertised source generation") == true)
}

@Test("durable V2 authority does not treat projection-updated checkpoint as intake heartbeat")
func durableV2AuthorityExpiresStaleCheckpoint() {
  let now = Date(timeIntervalSince1970: 10_000)
  let checkpoint = durabilityCheckpoint(
    generation: "west-v2",
    updatedAt: now,
    intakeHeartbeatAt: now.addingTimeInterval(-46)
  )
  let resolution = OperationsEvidenceResolver.ingestionAuthority(
    services: [durableV2Worker(generation: "west-v2", at: now)],
    streams: [],
    durability: IngestionDurabilitySnapshot(
      environment: "dev",
      checkpoints: [checkpoint],
      generatedAt: now
    ),
    at: now
  )

  #expect(resolution.durableCheckpoint == checkpoint)
  #expect(resolution.state?.transportHeartbeatAt == now.addingTimeInterval(-46))
  #expect(resolution.durableCheckpoint?.updatedAt == now)
  #expect(resolution.evidence.accuracy == .unavailable)
  #expect(resolution.evidence.indexedThrough == nil)
  #expect(resolution.evidence.lastSuccessfulAt == checkpoint.intakeHeartbeatAt)
  #expect(resolution.evidence.degradedReason?.contains("expired") == true)
}

@Test("completed bounded snapshot remains healthy without an intake heartbeat")
func completedBoundedSnapshotIsHealthyTerminalEvidence() {
  let now = Date(timeIntervalSince1970: 10_000)
  let checkpoint = durabilityCheckpoint(
    generation: "west-v2",
    updatedAt: now.addingTimeInterval(-3_600),
    replayState: .snapshotComplete,
    includeIntakeHeartbeat: false
  )
  let resolution = OperationsEvidenceResolver.ingestionAuthority(
    services: [durableV2Worker(generation: "west-v2", at: now)],
    streams: [],
    durability: IngestionDurabilitySnapshot(
      environment: "dev",
      checkpoints: [checkpoint],
      generatedAt: now
    ),
    at: now
  )

  #expect(resolution.state?.connectionState == .connected)
  #expect(resolution.state?.transportHeartbeatAt == nil)
  #expect(resolution.state?.lastDisconnectReason == nil)
  #expect(resolution.evidence.accuracy == .exact)
  #expect(resolution.evidence.indexedThrough == checkpoint.updatedAt)
  #expect(resolution.evidence.validUntil == .distantFuture)
  #expect(resolution.evidence.degradedReason == nil)
}

private func durableV2Worker(generation: String, at now: Date) -> OperationsServiceState {
  OperationsServiceState(
    service: "appview-worker",
    environment: "dev",
    instanceId: "worker-v2",
    liveness: .healthy,
    readiness: .healthy,
    freshness: .healthy,
    completeness: .healthy,
    dependencyState: [
      "ingestion_authority": OperationsEvidenceResolver.durableJetstreamV2AuthoritySource,
      "jetstream_v2_source_generation": generation,
    ],
    startedAt: now.addingTimeInterval(-60),
    heartbeatAt: now
  )
}

private func durabilityCheckpoint(
  generation: String,
  updatedAt: Date,
  intakeHeartbeatAt: Date? = nil,
  replayState: JetstreamReplayState = .live,
  includeIntakeHeartbeat: Bool = true
) -> JetstreamDurabilityCheckpoint {
  JetstreamDurabilityCheckpoint(
    environment: "dev",
    sourceGeneration: generation,
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
