import Foundation

public struct IngestionAuthorityResolution: Sendable {
  public let source: String?
  public let state: IngestionStreamState?
  public let durableCheckpoint: JetstreamDurabilityCheckpoint?
  public let durableInbox: IngestionInboxMetrics?
  public let evidence: OperationsEvidenceMetadata
}

public enum OperationsEvidenceResolver {
  public static let requiredServiceNames = ["gateway", "appview", "appview-worker", "operations"]
  public static let durableJetstreamV2AuthoritySource = "jetstream_v2_inbox"

  public static func services(
    _ states: [OperationsServiceState],
    requiredServices: [String] = requiredServiceNames,
    source: String = "operations_service_state",
    at: Date = Date(),
    validitySeconds: TimeInterval = 45
  ) -> OperationsEvidenceMetadata {
    let selected = requiredServices.compactMap { requiredService in
      states.filter { $0.service == requiredService }
        .max(by: { $0.heartbeatAt < $1.heartbeatAt })
    }
    let freshNames = Set(selected.filter {
      at.timeIntervalSince($0.heartbeatAt) <= validitySeconds
    }.map(\.service))
    let missingOrExpired = requiredServices.filter { !freshNames.contains($0) }
    let watermark = selected.map(\.heartbeatAt).min()
    let unavailable = freshNames.isEmpty
    let complete = missingOrExpired.isEmpty
    return OperationsEvidenceMetadata(
      source: source,
      accuracy: unavailable ? .unavailable : (complete ? .exact : .sampled),
      generatedAt: at,
      indexedThrough: watermark,
      ageSeconds: watermark.map { max(0, at.timeIntervalSince($0)) } ?? 0,
      validUntil: watermark?.addingTimeInterval(validitySeconds) ?? at,
      coverage: requiredServices.isEmpty
        ? 0 : Double(freshNames.count) / Double(requiredServices.count),
      lastSuccessfulAt: watermark,
      degradedReason: complete ? nil
        : "Missing or expired required service evidence: \(missingOrExpired.joined(separator: ", ")).")
  }

  public static func ingestionAuthority(
    services: [OperationsServiceState],
    streams: [IngestionStreamState],
    durability: IngestionDurabilitySnapshot? = nil,
    at: Date = Date()
  ) -> IngestionAuthorityResolution {
    let worker = services.filter {
      $0.service == "appview-worker" && at.timeIntervalSince($0.heartbeatAt) <= 15
    }.max(by: { $0.heartbeatAt < $1.heartbeatAt })
    let advertised = worker?.dependencyState["ingestion_authority"]
    let recognizedSources = ["jetstream", "tap", durableJetstreamV2AuthoritySource]
    let authoritySource = advertised.flatMap { recognizedSources.contains($0) ? $0 : nil }

    if authoritySource == durableJetstreamV2AuthoritySource {
      return durableJetstreamV2Authority(
        worker: worker,
        durability: durability,
        at: at
      )
    }

    let authorityState = authoritySource.flatMap { source in
      streams.first(where: { $0.source == source })
    }
    let heartbeat = authorityState?.transportHeartbeatAt
    let heartbeatIsFresh = heartbeat.map { at.timeIntervalSince($0) <= 45 } ?? false
    let degradedReason: String?
    if authoritySource == nil {
      degradedReason = "No fresh ingestion-authority capability evidence is available."
    } else if heartbeat == nil {
      degradedReason = "No transport heartbeat exists for the authoritative ingestion source."
    } else if !heartbeatIsFresh {
      degradedReason = "The authoritative ingestion transport heartbeat has expired."
    } else {
      degradedReason = nil
    }
    return IngestionAuthorityResolution(
      source: authoritySource,
      state: authorityState,
      durableCheckpoint: nil,
      durableInbox: nil,
      evidence: OperationsEvidenceMetadata(
        source: "appview_ingestion_stream_state",
        accuracy: heartbeatIsFresh ? .exact : .unavailable,
        generatedAt: at,
        indexedThrough: heartbeat,
        ageSeconds: heartbeat.map { max(0, at.timeIntervalSince($0)) } ?? 0,
        validUntil: heartbeat?.addingTimeInterval(45) ?? at,
        coverage: heartbeatIsFresh ? 1 : 0,
        lastSuccessfulAt: heartbeat,
        degradedReason: degradedReason
      )
    )
  }

  private static func durableJetstreamV2Authority(
    worker: OperationsServiceState?,
    durability: IngestionDurabilitySnapshot?,
    at: Date,
    validitySeconds: TimeInterval = 45
  ) -> IngestionAuthorityResolution {
    let sourceGeneration = worker?.dependencyState["jetstream_v2_source_generation"]
    let checkpoint = sourceGeneration.flatMap { expectedGeneration in
      durability?.checkpoints.first {
        $0.environment == worker?.environment
          && $0.sourceGeneration == expectedGeneration
          && $0.cursorKind == .jetstreamV2Sequence
      }
    }
    let authorityInbox = sourceGeneration.flatMap { generation in
      durability.map { $0.inboxBySourceGeneration[generation] ?? IngestionInboxMetrics() }
    }
    let terminalSnapshot = checkpoint?.replayState == .snapshotComplete
    let observedAt = terminalSnapshot ? checkpoint?.updatedAt : checkpoint?.intakeHeartbeatAt
    let age = observedAt.map { at.timeIntervalSince($0) }
    let isFresh = terminalSnapshot || (age.map { $0 >= 0 && $0 <= validitySeconds } ?? false)
    let authorityState = checkpoint.map {
      durableJetstreamV2State(
        checkpoint: $0,
        inbox: authorityInbox ?? IngestionInboxMetrics(),
        observedAt: durability?.generatedAt ?? at,
        validitySeconds: validitySeconds
      )
    }

    let degradedReason: String?
    if sourceGeneration == nil {
      degradedReason = "The durable Jetstream V2 source generation is not advertised."
    } else if durability == nil {
      degradedReason = "Durable Jetstream V2 checkpoint evidence is unavailable."
    } else if checkpoint == nil {
      degradedReason = "No matching durable Jetstream V2 checkpoint exists for the advertised source generation."
    } else if observedAt == nil {
      degradedReason = "No active fenced Jetstream V2 intake lease exists for the advertised source generation."
    } else if !isFresh {
      degradedReason = "The fenced Jetstream V2 intake lease heartbeat has expired."
    } else {
      degradedReason = nil
    }

    return IngestionAuthorityResolution(
      source: durableJetstreamV2AuthoritySource,
      state: authorityState,
      durableCheckpoint: checkpoint,
      durableInbox: authorityInbox,
      evidence: OperationsEvidenceMetadata(
        source: "appview_jetstream_checkpoints",
        accuracy: isFresh ? .exact : .unavailable,
        generatedAt: at,
        indexedThrough: isFresh ? observedAt : nil,
        ageSeconds: isFresh ? max(0, age ?? 0) : 0,
        validUntil: terminalSnapshot ? .distantFuture
          : (observedAt?.addingTimeInterval(validitySeconds) ?? at),
        coverage: isFresh ? 1 : 0,
        lastSuccessfulAt: observedAt,
        degradedReason: degradedReason
      )
    )
  }

  private static func durableJetstreamV2State(
    checkpoint: JetstreamDurabilityCheckpoint,
    inbox: IngestionInboxMetrics,
    observedAt: Date,
    validitySeconds: TimeInterval
  ) -> IngestionStreamState {
    let connectionState: IngestionConnectionState
    switch checkpoint.replayState {
    case .failed:
      connectionState = .disconnected
    case .pausedBudget:
      connectionState = .reconnecting
    case .idle, .replaying, .live, .snapshotComplete:
      connectionState = .connected
    }
    let lastDisconnectReason: String? = switch checkpoint.replayState {
    case .failed: "durable_replay_failed"
    case .pausedBudget: "replay_budget_paused"
    case .idle, .replaying, .live, .snapshotComplete: nil
    }
    let queueDepth = inbox.pending + inbox.leased + inbox.retrying
    let queueEvidence = OperationsEvidenceMetadata(
      source: "appview_ingestion_inbox",
      accuracy: .exact,
      generatedAt: observedAt,
      indexedThrough: observedAt,
      ageSeconds: 0,
      validUntil: observedAt.addingTimeInterval(validitySeconds),
      coverage: 1,
      lastSuccessfulAt: observedAt
    )
    return IngestionStreamState(
      environment: checkpoint.environment,
      source: durableJetstreamV2AuthoritySource,
      connectionState: connectionState,
      lastDisconnectAt: checkpoint.replayState == .failed ? checkpoint.updatedAt : nil,
      lastDisconnectReason: lastDisconnectReason,
      lastReceivedCursor: checkpoint.lastStagedSequence,
      lastReceivedEventAt: checkpoint.lastStagedEventAt,
      lastReceivedAt: checkpoint.lastStagedAt,
      lastCommittedCursor: checkpoint.lastAppliedSequence,
      lastCommittedEventAt: checkpoint.lastAppliedEventAt,
      lastCommittedAt: checkpoint.lastAppliedAt,
      queueDepth: queueDepth,
      queueEvidence: queueEvidence,
      transportHeartbeatAt: checkpoint.intakeHeartbeatAt,
      lastIndexedMutationAt: checkpoint.lastAppliedAt,
      projectionWatermark: checkpoint.lastAppliedSequence.map(String.init),
      validationWatermark: checkpoint.lastReconciledRepositoryRevision,
      heartbeatAt: checkpoint.intakeHeartbeatAt ?? checkpoint.updatedAt
    )
  }
}
