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
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      httpClient: httpClient,
      plcURL: plcURL,
      rssIngestion: httpClient.map {
        ThinAppViewRssIngestion(store: store, httpClient: $0, config: config, logger: logger)
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

    logger.info("Starting thin AppView worker")

    try await withThrowingTaskGroup(of: Void.self) { group in
      if tapConfiguration?.mode != .authoritative {
        group.addTask { await firehose.runForever() }
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
          repositoryRestorer: enrollmentBackfill.map {
            TapPDSRepositoryRestorer(
              store: store,
              backfill: $0,
              maxConcurrency: config.maxEnrollConcurrency,
              rateLimitPerSecond: max(1, config.maxEnrollConcurrency * 10)
            )
          },
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
        if config.proactiveBackfillEnabled {
          let proactive = ThinAppViewProactiveBackfillJob(
            store: store,
            backfill: backfill,
            config: config,
            logger: logger,
            extraAuthorDids: proactiveExtraAuthorDids
          )
          group.addTask { await proactive.runForever() }
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
          pdsReconciliationAvailable: enrollmentBackfill != nil
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
          logger: logger
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
    pdsReconciliationAvailable: Bool
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
      let authoritySource = tapMode == .authoritative ? "tap" : "jetstream"
      let authority = tapMode == .authoritative ? tap : jetstream

      let jetstreamReplay = operationsConfig.recoveryEnabled
        ? "enabled_unverified"
        : "disabled_by_release_gate"
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
        freshness: projectionEvidence.freshness,
        completeness: projectionEvidence.completeness,
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
}

struct ProjectionRepairHealthEvidence: Sendable {
  let freshness: OperationsHealthState
  let completeness: OperationsHealthState
  let metadata: [String: String]
}
