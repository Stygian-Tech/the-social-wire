import AsyncHTTPClient
import Foundation
import Logging
import OperationsCore

/// Runs firehose ingestion, proactive PDS backfill, and TTL cleanup until one task exits or throws.
public enum ThinAppViewWorkerRuntime {
  public static func run(
    store: any ThinAppViewStore,
    config: ThinAppViewConfig,
    logger: Logger,
    httpClient: HTTPClient? = nil,
    plcURL: String? = nil,
    proactiveExtraAuthorDids: [String] = [],
    projectionCache: (any AppViewProjectionCacheStore)? = nil,
    operationsStore: (any OperationsStore)? = nil,
    operationsConfig: OperationsConfiguration? = nil,
    tapConfiguration: TapConsumerConfiguration? = nil
  ) async throws {
    if config.jetstreamMode == .v2Authoritative,
      tapConfiguration?.mode == .authoritative
    {
      throw ThinAppViewWorkerRuntimeError.conflictingIngestionAuthorities
    }
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      httpClient: httpClient,
      plcURL: plcURL,
      rssIngestion: httpClient.map {
        ThinAppViewRssIngestion(
          store: store,
          httpClient: $0,
          config: config,
          logger: logger,
          projectionCache: projectionCache
        )
      },
      projectionCache: projectionCache
    )
    let telemetry = operationsStore.map { OperationsTelemetryBuffer(store: $0, logger: logger) }
    let enrollmentBackfill: ThinAppViewEnrollBackfill? = if let httpClient, let plcURL {
      ThinAppViewEnrollBackfill(
        store: store,
        indexer: indexer,
        httpClient: httpClient,
        plcURL: plcURL,
        config: config,
        logger: logger
      )
    } else {
      nil
    }
    let firehose = FirehoseSubscriber(
      relayURLs: config.relayWebSocketURLs,
      indexer: indexer,
      operationsStore: operationsStore,
      telemetry: telemetry,
      environment: operationsConfig?.environment ?? "unknown",
      instanceId: operationsConfig?.instanceId ?? "unknown",
      replayRewindMicroseconds: operationsConfig?.replayRewindMicroseconds ?? 5_000_000,
      logger: logger
    )
    let cleanup = ThinAppViewTtlCleanupJob(
      store: store,
      projectionCache: projectionCache,
      config: config,
      tapStorageEnabled: tapConfiguration?.mode != .disabled,
      environment: operationsConfig?.environment ?? "unknown",
      logger: logger
    )
    let projectionRepair = ThinAppViewProjectionRepairJob(
      store: store,
      projectionCache: projectionCache,
      operationsStore: operationsStore,
      environment: operationsConfig?.environment ?? "unknown",
      workerId: operationsConfig?.instanceId ?? "appview-worker",
      telemetry: telemetry,
      logger: logger
    )
    let repositoryRestorer: (any TapRepositoryRestorer)? = enrollmentBackfill.map {
      TapPDSRepositoryRestorer(
        store: store,
        backfill: $0,
        projectionCache: projectionCache,
        maxConcurrency: config.maxEnrollConcurrency,
        rateLimitPerSecond: max(1, config.maxEnrollConcurrency * 10)
      )
    }
    let inboxWorker: JetstreamInboxProjectionWorker? = if config.jetstreamMode.drainsV2Inbox {
      JetstreamInboxProjectionWorker(
        store: store,
        indexers: (0..<config.ingestionInboxMaxConcurrency).map { _ in
          ThinAppViewIndexer(
            store: store,
            config: config,
            logger: logger,
            httpClient: httpClient,
            plcURL: plcURL,
            rssIngestion: httpClient.map {
              ThinAppViewRssIngestion(
                store: store,
                httpClient: $0,
                config: config,
                logger: logger,
                projectionCache: projectionCache
              )
            },
            projectionCache: projectionCache
          )
        },
        repositoryRestorer: repositoryRestorer,
        environment: operationsConfig?.environment ?? "unknown",
        sourceGeneration: config.jetstreamV2SourceGeneration,
        workerId: operationsConfig?.instanceId ?? "appview-worker",
        maxConcurrency: config.ingestionInboxMaxConcurrency,
        leaseSeconds: config.ingestionInboxLeaseSeconds,
        pollMilliseconds: config.ingestionInboxPollMilliseconds,
        appliedRetentionSeconds: config.ingestionInboxAppliedRetentionSeconds,
        deadLetterRetentionSeconds: config.ingestionInboxDeadLetterRetentionSeconds,
        logger: logger
      )
    } else {
      nil
    }

    logger.info(
      "Starting Charybdis",
      metadata: ["jetstream_mode": .string(config.jetstreamMode.rawValue)]
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      if tapConfiguration?.mode != .authoritative, config.jetstreamMode.runsLegacySubscriber {
        group.addTask {
          await LegacyJetstreamAuthorityLease.runForever(
            store: operationsStore,
            ownerID: operationsConfig?.instanceId ?? "appview-worker",
            logger: logger
          ) { lease in
            await firehose.runForever(authorityLease: lease)
          }
        }
      }
      if let inboxWorker {
        group.addTask { await inboxWorker.runForever() }
      }
      group.addTask { await cleanup.runForever() }
      if tapConfiguration?.mode != .disabled {
        group.addTask { await projectionRepair.runForever() }
      }
      if let telemetry { group.addTask { await telemetry.runForever() } }

      if let tapConfiguration, tapConfiguration.mode != .disabled {
        let tapConsumer = TapConsumer(
          store: store,
          indexer: indexer,
          configuration: tapConfiguration,
          repositoryRestorer: repositoryRestorer,
          operationsStore: operationsStore,
          telemetry: telemetry,
          instanceId: operationsConfig?.instanceId ?? "unknown",
          logger: logger
        )
        group.addTask { await tapConsumer.runForever() }
        if let httpClient {
          let tapTracker = TapRepositoryTracker(
            store: store,
            httpClient: httpClient,
            configuration: tapConfiguration,
            logger: logger
          )
          group.addTask { await tapTracker.runForever() }
        }
      }

      if let backfill = enrollmentBackfill {
        if config.proactiveBackfillEnabled && config.jetstreamMode.runsLegacyProactiveBackfill {
          let proactive = ThinAppViewProactiveBackfillJob(
            store: store,
            backfill: backfill,
            config: config,
            logger: logger,
            extraAuthorDids: proactiveExtraAuthorDids
          )
          group.addTask { await proactive.runForever() }
        } else if config.proactiveBackfillEnabled {
          logger.info(
            "Suppressing legacy proactive AppView backfill under durable Jetstream V2 authority"
          )
        }

        if let operationsStore, let operationsConfig, operationsConfig.recoveryEnabled {
          let recovery = ThinAppViewRecoveryJobRunner(
            store: operationsStore,
            indexer: indexer,
            pdsBackfill: backfill,
            relayURL: config.relayWebSocketURL,
            workerId: operationsConfig.instanceId,
            logger: logger
          )
          group.addTask { await recovery.runForever() }
        }
      }

      if let operationsStore, let operationsConfig, operationsConfig.enabled {
        let dependencyProbe = workerDependencyProbe(
          store: store,
          operationsStore: operationsStore,
          operationsConfig: operationsConfig,
          tapConfiguration: tapConfiguration,
          pdsReconciliationAvailable: enrollmentBackfill != nil,
          jetstreamMode: config.jetstreamMode,
          jetstreamV2SourceGeneration: config.jetstreamV2SourceGeneration
        )
        let heartbeat = OperationsHeartbeatJob(
          store: operationsStore,
          service: "appview-worker",
          environment: operationsConfig.environment,
          instanceId: operationsConfig.instanceId,
          dependencyProbe: dependencyProbe,
          telemetry: telemetry,
          logger: logger
        )
        group.addTask { await heartbeat.runForever() }
      }

      if config.rssFeedPollEnabled, let httpClient {
        let rssIngestion = ThinAppViewRssIngestion(
          store: store,
          httpClient: httpClient,
          config: config,
          logger: logger,
          projectionCache: projectionCache
        )
        let rssPoll = ThinAppViewRssFeedPollJob(
          store: store,
          rssIngestion: rssIngestion,
          config: config,
          logger: logger
        )
        group.addTask { await rssPoll.runForever() }
      }

      try await group.next()
      group.cancelAll()
    }
  }

  static func workerDependencyProbe(
    store: any ThinAppViewStore,
    operationsStore: any OperationsStore,
    operationsConfig: OperationsConfiguration,
    tapConfiguration: TapConsumerConfiguration?,
    pdsReconciliationAvailable: Bool,
    jetstreamMode: ThinAppViewJetstreamMode = .v1Authoritative,
    jetstreamV2SourceGeneration: String = "jetstream-v2-us-west-v1"
  ) -> OperationsServiceDependencyProbe {
    {
      try await store.ping()
      let now = Date()
      let tapMode = tapConfiguration?.mode ?? .disabled
      let jetstream = Self.transportEvidence(
        try await operationsStore.fetchStreamState(source: "jetstream"),
        at: now
      )
      let tap = Self.transportEvidence(
        try await operationsStore.fetchStreamState(source: "tap"),
        at: now
      )
      let durability = try await operationsStore.fetchIngestionDurabilitySnapshot(at: now)
      let durableCheckpoint = durability.checkpoints.first {
        $0.sourceGeneration == jetstreamV2SourceGeneration
      }
      let durableTransport = Self.durableTransportEvidence(durableCheckpoint, at: now)
      let durableProjection = Self.durableProjectionHealthEvidence(
        durability,
        checkpoint: durableCheckpoint
      )
      let projectionBacklog = try await store.projectionRepairBacklog(
        environment: operationsConfig.environment,
        at: now
      )
      let projectionEvidence = Self.projectionRepairHealthEvidence(
        projectionBacklog,
        expectedEnvironment: operationsConfig.environment,
        tapMode: tapMode,
        at: now
      )
      // Jetstream remains the indexing authority throughout shadow mode. Tap health must be
      // published independently, but a healthy shadow may not conceal a dead authority stream.
      let authoritySource: String
      let authority: TransportEvidence
      if tapMode == .authoritative {
        authoritySource = "tap"
        authority = tap
      } else if jetstreamMode == .v2Authoritative {
        authoritySource = "jetstream_v2_inbox"
        authority = durableTransport
      } else {
        authoritySource = "jetstream"
        authority = jetstream
      }

      let jetstreamReplay: String
      switch jetstreamMode {
      case .v2Authoritative: jetstreamReplay = "enabled_durable_v2"
      case .v2Shadow: jetstreamReplay = "shadow_staging"
      case .v1Authoritative:
        jetstreamReplay = operationsConfig.recoveryEnabled
          ? "enabled_unverified" : "disabled_by_release_gate"
      }
      let pdsReconciliation = operationsConfig.recoveryEnabled && pdsReconciliationAvailable
        ? "enabled_diagnostic_only"
        : "disabled"
      let validationSupport: String
      switch tapMode {
      case .shadow: validationSupport = "shadow_parity"
      case .authoritative: validationSupport = "event_validation_only"
      case .disabled: validationSupport = "disabled"
      }
      let observedAt = min(authority.heartbeatAt ?? now, projectionBacklog.observedAt)
      let transportValidUntil = authority.heartbeatAt?.addingTimeInterval(30)
        ?? now.addingTimeInterval(5)
      return OperationsServiceProbeResult(
        liveness: authority.health,
        readiness: authority.health,
        freshness: jetstreamMode == .v2Authoritative
          ? durableProjection.freshness : projectionEvidence.freshness,
        completeness: jetstreamMode == .v2Authoritative
          ? durableProjection.completeness : projectionEvidence.completeness,
        dependencyState: [
          "appview_database": "ready",
          "ingestion_transport": authority.dependency,
          "ingestion_source": authoritySource,
          "ingestion_authority": authoritySource,
          "jetstream_transport": jetstream.dependency,
          "jetstream_role": tapMode == .authoritative
            ? "supplemental_unverified" : "authoritative_unverified",
          "tap_transport": tapMode == .disabled ? "disabled" : tap.dependency,
          "tap_role": tapMode.rawValue,
          "tap_consumer_mode": tapMode.rawValue,
          "tap_validation_support": validationSupport,
          "tap_verified_resync": "unsupported",
          "jetstream_replay": jetstreamReplay,
          "jetstream_v2_source_generation": jetstreamV2SourceGeneration,
          "jetstream_v2_inbox_pending": String(durability.inbox.pending),
          "jetstream_v2_inbox_retrying": String(durability.inbox.retrying),
          "jetstream_v2_dead_letters": String(durability.inbox.deadLetters),
          "pds_reconciliation": pdsReconciliation,
        ].merging(projectionEvidence.metadata) { _, projectionValue in projectionValue },
        requiredDependencyKeys: ["appview_database", "ingestion_transport"],
        observedAt: observedAt,
        validUntil: min(
          transportValidUntil,
          projectionBacklog.observedAt.addingTimeInterval(5)
        )
      )
    }
  }

  static func projectionRepairHealthEvidence(
    _ snapshot: AppViewProjectionRepairBacklogSnapshot,
    expectedEnvironment: String,
    tapMode: TapConsumerMode,
    at now: Date
  ) -> ProjectionRepairHealthEvidence {
    let oldestTimestamp = snapshot.oldestActionableAt.map {
      ISO8601DateFormatter().string(from: $0)
    } ?? "none"
    let oldestAge = snapshot.oldestActionableAgeSeconds.map {
      String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0)
    } ?? "none"
    var metadata = [
      "projection_repair_queued_count": String(snapshot.queuedCount),
      "projection_repair_running_count": String(snapshot.runningCount),
      "projection_repair_failed_count": String(snapshot.failedCount),
      "projection_repair_oldest_actionable_at": oldestTimestamp,
      "projection_repair_oldest_actionable_age_seconds": oldestAge,
      "projection_repair_observed_at": ISO8601DateFormatter().string(from: snapshot.observedAt),
    ]

    let firstTotal = snapshot.queuedCount.addingReportingOverflow(snapshot.runningCount)
    let total = firstTotal.partialValue.addingReportingOverflow(snapshot.failedCount)
    let evidenceAge = now.timeIntervalSince(snapshot.observedAt)
    guard snapshot.environment == expectedEnvironment,
      snapshot.queuedCount >= 0,
      snapshot.runningCount >= 0,
      snapshot.failedCount >= 0,
      !firstTotal.overflow,
      !total.overflow,
      evidenceAge >= 0,
      evidenceAge <= 5
    else {
      metadata["projection_repair_backlog"] = "unknown"
      return ProjectionRepairHealthEvidence(
        freshness: .unknown,
        completeness: .unknown,
        metadata: metadata
      )
    }

    if total.partialValue == 0 {
      guard snapshot.oldestActionableAt == nil,
        snapshot.oldestActionableAgeSeconds == nil
      else {
        metadata["projection_repair_backlog"] = "unknown"
        return ProjectionRepairHealthEvidence(
          freshness: .unknown,
          completeness: .unknown,
          metadata: metadata
        )
      }
      guard tapMode == .authoritative else {
        metadata["projection_repair_backlog"] = "not_authoritative"
        return ProjectionRepairHealthEvidence(
          freshness: .unknown,
          completeness: .unknown,
          metadata: metadata
        )
      }
      metadata["projection_repair_backlog"] = "ready"
      return ProjectionRepairHealthEvidence(
        freshness: .healthy,
        completeness: .healthy,
        metadata: metadata
      )
    }

    guard let oldestAt = snapshot.oldestActionableAt,
      let reportedAge = snapshot.oldestActionableAgeSeconds
    else {
      metadata["projection_repair_backlog"] = "unknown"
      return ProjectionRepairHealthEvidence(
        freshness: .unknown,
        completeness: .unknown,
        metadata: metadata
      )
    }
    let measuredAge = snapshot.observedAt.timeIntervalSince(oldestAt)
    guard reportedAge >= 0,
      measuredAge >= 0,
      abs(reportedAge - measuredAge) <= 0.001
    else {
      metadata["projection_repair_backlog"] = "unknown"
      return ProjectionRepairHealthEvidence(
        freshness: .unknown,
        completeness: .unknown,
        metadata: metadata
      )
    }

    if snapshot.failedCount > 0 {
      metadata["projection_repair_backlog"] = "failed"
      return ProjectionRepairHealthEvidence(
        freshness: .unhealthy,
        completeness: .unhealthy,
        metadata: metadata
      )
    }
    if reportedAge > 5 {
      metadata["projection_repair_backlog"] = "overdue"
      return ProjectionRepairHealthEvidence(
        freshness: .unhealthy,
        completeness: .unhealthy,
        metadata: metadata
      )
    }
    metadata["projection_repair_backlog"] = "pending"
    return ProjectionRepairHealthEvidence(
      freshness: .degraded,
      completeness: .degraded,
      metadata: metadata
    )
  }

  private struct TransportEvidence {
    let health: OperationsHealthState
    let dependency: String
    let heartbeatAt: Date?
  }

  private static func transportEvidence(
    _ stream: IngestionStreamState?,
    at now: Date
  ) -> TransportEvidence {
    guard let heartbeatAt = stream?.transportHeartbeatAt else {
      return TransportEvidence(health: .unknown, dependency: "missing", heartbeatAt: nil)
    }
    let age = now.timeIntervalSince(heartbeatAt)
    guard age >= 0, age <= 30 else {
      return TransportEvidence(health: .unknown, dependency: "expired", heartbeatAt: heartbeatAt)
    }
    guard stream?.connectionState == .connected else {
      return TransportEvidence(
        health: .degraded,
        dependency: "disconnected",
        heartbeatAt: heartbeatAt
      )
    }
    return TransportEvidence(health: .healthy, dependency: "ready", heartbeatAt: heartbeatAt)
  }

  private static func durableTransportEvidence(
    _ checkpoint: JetstreamDurabilityCheckpoint?,
    at now: Date
  ) -> TransportEvidence {
    guard let checkpoint, checkpoint.cursorKind == .jetstreamV2Sequence else {
      return TransportEvidence(health: .unknown, dependency: "missing", heartbeatAt: nil)
    }
    let age = now.timeIntervalSince(checkpoint.updatedAt)
    guard age >= 0, age <= 30 else {
      return TransportEvidence(
        health: .unknown,
        dependency: "expired",
        heartbeatAt: checkpoint.updatedAt
      )
    }
    guard checkpoint.replayState != .failed else {
      return TransportEvidence(
        health: .unhealthy,
        dependency: "replay_failed",
        heartbeatAt: checkpoint.updatedAt
      )
    }
    return TransportEvidence(
      health: checkpoint.replayState == .pausedBudget ? .degraded : .healthy,
      dependency: checkpoint.replayState == .pausedBudget ? "paused_budget" : "ready",
      heartbeatAt: checkpoint.updatedAt
    )
  }

  private static func durableProjectionHealthEvidence(
    _ snapshot: IngestionDurabilitySnapshot,
    checkpoint: JetstreamDurabilityCheckpoint?
  ) -> ProjectionRepairHealthEvidence {
    guard checkpoint != nil else {
      return ProjectionRepairHealthEvidence(
        freshness: .unknown,
        completeness: .unknown,
        metadata: ["durable_ingestion": "missing_checkpoint"]
      )
    }
    let oldestAge = snapshot.inbox.oldestPendingAgeSeconds
    let freshness: OperationsHealthState
    if let oldestAge, oldestAge > 15 * 60 {
      freshness = .unhealthy
    } else if let oldestAge, oldestAge > 60 {
      freshness = .degraded
    } else {
      freshness = .healthy
    }
    let completeness: OperationsHealthState = snapshot.inbox.deadLetters > 0
      ? .unhealthy : .healthy
    return ProjectionRepairHealthEvidence(
      freshness: freshness,
      completeness: completeness,
      metadata: [
        "durable_ingestion": "ready",
        "durable_inbox_oldest_pending_age_seconds": oldestAge.map { String($0) } ?? "none",
      ]
    )
  }
}

public enum ThinAppViewWorkerRuntimeError: Error, Sendable, Equatable {
  case conflictingIngestionAuthorities
}

struct ProjectionRepairHealthEvidence: Sendable {
  let freshness: OperationsHealthState
  let completeness: OperationsHealthState
  let metadata: [String: String]
}
