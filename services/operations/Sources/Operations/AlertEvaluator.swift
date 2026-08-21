import Foundation
import Logging
import OperationsCore

struct AlertEvaluator {
  static let durableInboxDegradedAgeSeconds: TimeInterval = 60
  static let durableInboxUnhealthyAgeSeconds: TimeInterval = 15 * 60

  let store: any OperationsStore
  let config: OperationsConfiguration
  let logger: Logger
  let webhook: OperationsWebhookDelivery?

  func runForever() async {
    while !Task.isCancelled {
      do {
        try await evaluate(at: Date())
      } catch {
        logger.error("Operations alert evaluation failed", metadata: ["error_type": .string("evaluation")])
      }
      try? await Task.sleep(for: .seconds(30))
    }
  }

  func evaluate(at now: Date) async throws {
    let services = try await store.listServiceStates()
    let streamStates = try await store.listStreamStates()
    let durability = try? await store.fetchIngestionDurabilitySnapshot(at: now)
    let authority = OperationsEvidenceResolver.ingestionAuthority(
      services: services,
      streams: streamStates,
      durability: durability,
      at: now
    )
    let worker = services.filter { $0.service == "appview-worker" }
      .max(by: { $0.heartbeatAt < $1.heartbeatAt })
    let authoritySource = authority.source
    try await reconcile(
      condition: authoritySource == nil,
      rule: "ingestion_authority_evidence_missing",
      conditionKey: "ingestion:authority_evidence_missing",
      severity: "critical",
      summary: "No fresh ingestion-authority capability evidence is available.",
      evidence: [
        "worker_heartbeat_at": worker?.heartbeatAt.ISO8601Format() ?? "none",
        "observedAt": worker?.heartbeatAt.ISO8601Format() ?? "none",
        "validUntil": worker?.heartbeatAt.addingTimeInterval(15).ISO8601Format() ?? "none",
      ],
      runbookSlug: "live-process-stalled-ingestion",
      at: now)

    let streamsBySource = Dictionary(uniqueKeysWithValues: streamStates.map { ($0.source, $0) })
    let tapRole = worker?.dependencyState["tap_role"]
    let tapEnabled = tapRole == "shadow" || tapRole == "authoritative"
    let durableV2IsAuthority = authoritySource
      == OperationsEvidenceResolver.durableJetstreamV2AuthoritySource
    var evaluatedSources = Set(streamsBySource.keys.filter {
      $0 != "tap" && $0 != OperationsEvidenceResolver.durableJetstreamV2AuthoritySource
    })
    if durableV2IsAuthority {
      evaluatedSources.remove("jetstream")
      try await resolveTransportAlerts(source: "jetstream", at: now)
      try await evaluateDurableV2Transport(checkpoint: authority.durableCheckpoint, at: now)
      try await evaluateDurableV2Backlog(
        inbox: authority.durableInbox,
        observedAt: durability?.generatedAt,
        checkpoint: authority.durableCheckpoint,
        at: now
      )
    } else {
      evaluatedSources.insert("jetstream")
      try await resolveDurableV2TransportAlerts(at: now)
      try await resolveDurableV2BacklogAlert(at: now)
    }
    if tapEnabled {
      evaluatedSources.insert("tap")
    } else {
      try await resolveTransportAlerts(source: "tap", at: now)
    }
    for source in evaluatedSources.sorted() {
      try await evaluateTransport(
        source: source, state: streamsBySource[source], isAuthority: authoritySource == source,
        at: now)
    }

    if durableV2IsAuthority {
      try await resolveLegacyJetstreamBacklogAlerts(at: now)
    } else {
      try await evaluateLegacyJetstreamBacklog(
        state: streamsBySource["jetstream"],
        isAuthority: authoritySource == "jetstream",
        at: now
      )
    }

    let counts = try await store.lifecycleCounts()
    let activeIncidents = durability.map {
      $0.incidents.open + $0.incidents.recovering + $0.incidents.verificationRequired
    }
    let deadLetters = durability?.inbox.deadLetters
    let durableRisk = durability.map { snapshot in
      (activeIncidents ?? 0) > 0 || snapshot.inbox.deadLetters > 0
    }
    try await reconcile(
      condition: durableRisk ?? (counts.activeGaps > 0),
      rule: durability == nil ? "active_ingestion_gap" : "active_ingestion_incident",
      conditionKey: "ingestion:active_gap",
      severity: "critical",
      summary: durability == nil
        ? "Legacy ingestion gap evidence requires investigation."
        : "A durable ingestion incident or dead letter requires recovery.",
      evidence: [
        "open_incident_count": activeIncidents.map(String.init) ?? "unavailable",
        "dead_letter_count": deadLetters.map(String.init) ?? "unavailable",
        "legacy_gap_signal_count": String(counts.activeGaps),
        "primary_evidence": durability == nil ? "legacy_gap_signals" : "durable_ingestion",
      ],
      runbookSlug: "confirming-and-scoping-a-gap",
      at: now)

    let activeBackfills = try await store.listBackfills(view: .active, limit: 250, before: nil).items
    let stalled = activeBackfills.filter {
      $0.status == .running && now.timeIntervalSince($0.updatedAt) >= config.backfillStallSeconds
    }
    try await reconcile(
      condition: !stalled.isEmpty,
      rule: "backfill_without_progress",
      conditionKey: "backfill:without_progress",
      severity: "critical",
      summary: "A running backfill has not reported progress within the configured threshold.",
      evidence: ["backfill_count": String(stalled.count)],
      runbookSlug: "running-and-validating-backfills",
      at: now)

    let attention = try await store.listBackfills(view: .attention, limit: 250, before: nil).items
    let failures = attention.filter { $0.status == .failed }
    try await reconcile(
      condition: !failures.isEmpty,
      rule: "terminal_backfill_failure",
      conditionKey: "backfill:terminal_failure",
      severity: "critical",
      summary: "A backfill ended in a terminal failure.",
      evidence: ["backfill_count": String(failures.count)],
      runbookSlug: "running-and-validating-backfills",
      at: now)

    try await evaluateMeasuredThresholds(at: now)

    guard config.alertDeliveryEnabled, let webhook else { return }
    let due = try await store.listAlertsPendingDelivery(limit: 100, at: now)
    for alert in due {
      do {
        try await webhook.deliver(alert)
        try await store.recordAlertDelivery(id: alert.id, error: nil, at: now)
      } catch {
        try await store.recordAlertDelivery(id: alert.id, error: "webhook_delivery_failed", at: now)
      }
    }
  }

  func evaluateDurableV2Transport(
    checkpoint: JetstreamDurabilityCheckpoint?,
    at now: Date
  ) async throws {
    let source = OperationsEvidenceResolver.durableJetstreamV2AuthoritySource
    let terminalSnapshot = checkpoint?.replayState == .snapshotComplete
    let observedAt = terminalSnapshot ? checkpoint?.updatedAt : checkpoint?.intakeHeartbeatAt
    let observedAge = observedAt.map { now.timeIntervalSince($0) }
    let identityValid = checkpoint?.cursorKind == .jetstreamV2Sequence
    let evidence: [String: String] = [
      "source_generation": checkpoint?.sourceGeneration ?? "none",
      "source_host": checkpoint?.sourceHost ?? "none",
      "cursor_kind": checkpoint?.cursorKind.rawValue ?? "none",
      "replay_state": checkpoint?.replayState.rawValue ?? "none",
      "snapshot_complete": String(terminalSnapshot),
      "replay_after_sequence": checkpoint?.replayAfterSequence.map(String.init) ?? "none",
      "replay_before_sequence": checkpoint?.replayBeforeSequence.map(String.init) ?? "none",
      "replay_sealed_sequence": checkpoint?.replaySealedSequence.map(String.init) ?? "none",
      "last_staged_sequence": checkpoint?.lastStagedSequence.map(String.init) ?? "none",
      "last_applied_sequence": checkpoint?.lastAppliedSequence.map(String.init) ?? "none",
      "checkpoint_updated_at": checkpoint?.updatedAt.ISO8601Format() ?? "none",
      "observedAt": observedAt?.ISO8601Format() ?? "none",
      "validUntil": observedAt?.addingTimeInterval(config.idleAlertSeconds).ISO8601Format()
        ?? "none",
    ]
    try await reconcile(
      condition: checkpoint == nil || !identityValid || (!terminalSnapshot && observedAt == nil),
      rule: "jetstream_v2_transport_evidence_missing",
      conditionKey: "\(source):transport_evidence_missing",
      severity: "critical",
      summary: "No matching durable Jetstream V2 checkpoint evidence is available for the authority source.",
      evidence: evidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now
    )
    try await reconcile(
      condition: !terminalSnapshot && identityValid && (observedAge.map {
        $0 < 0 || $0 >= config.idleAlertSeconds
      } ?? false),
      rule: "jetstream_v2_transport_heartbeat_expired",
      conditionKey: "\(source):transport_heartbeat_expired",
      severity: "critical",
      summary: "The durable Jetstream V2 intake lease heartbeat has expired for the authority source.",
      evidence: evidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now
    )
    try await reconcile(
      condition: checkpoint?.replayState == .failed,
      rule: "jetstream_v2_replay_failed",
      conditionKey: "\(source):replay_failed",
      severity: "critical",
      summary: "The authoritative durable Jetstream V2 replay is in a failed state.",
      evidence: evidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now
    )
  }

  private func resolveDurableV2TransportAlerts(at: Date) async throws {
    let source = OperationsEvidenceResolver.durableJetstreamV2AuthoritySource
    for conditionKey in [
      "\(source):transport_evidence_missing",
      "\(source):transport_heartbeat_expired",
      "\(source):replay_failed",
    ] {
      try await store.resolveAlert(conditionKey: conditionKey, at: at)
    }
  }

  func evaluateDurableV2Backlog(
    inbox: IngestionInboxMetrics?,
    observedAt: Date?,
    checkpoint: JetstreamDurabilityCheckpoint?,
    at now: Date
  ) async throws {
    let conditionKey = "jetstream_v2_inbox:actionable_backlog_overdue"
    guard let inbox, let oldestAge = inbox.oldestPendingAgeSeconds,
      oldestAge > Self.durableInboxDegradedAgeSeconds
    else {
      try await store.resolveAlert(conditionKey: conditionKey, at: now)
      return
    }

    let unhealthy = oldestAge > Self.durableInboxUnhealthyAgeSeconds
    let severity = unhealthy ? "critical" : "warning"
    let threshold = unhealthy
      ? Self.durableInboxUnhealthyAgeSeconds : Self.durableInboxDegradedAgeSeconds
    try await reconcile(
      condition: true,
      rule: "jetstream_v2_actionable_backlog_overdue",
      conditionKey: conditionKey,
      severity: severity,
      summary: unhealthy
        ? "The authoritative Jetstream V2 inbox has actionable work older than 15 minutes."
        : "The authoritative Jetstream V2 inbox has actionable work older than 60 seconds.",
      evidence: [
        "source_generation": checkpoint?.sourceGeneration ?? "none",
        "replay_state": checkpoint?.replayState.rawValue ?? "none",
        "pending_count": String(inbox.pending),
        "leased_count": String(inbox.leased),
        "retrying_count": String(inbox.retrying),
        "oldest_actionable_age_seconds": String(oldestAge),
        "threshold_seconds": String(threshold),
        "observedAt": observedAt?.ISO8601Format() ?? "none",
        "validUntil": observedAt?.addingTimeInterval(5).ISO8601Format() ?? "none",
      ],
      runbookSlug: "live-process-stalled-ingestion",
      at: now
    )
  }

  private func resolveDurableV2BacklogAlert(at: Date) async throws {
    try await store.resolveAlert(
      conditionKey: "jetstream_v2_inbox:actionable_backlog_overdue",
      at: at
    )
  }

  private func evaluateLegacyJetstreamBacklog(
    state jetstreamState: IngestionStreamState?,
    isAuthority: Bool,
    at now: Date
  ) async throws {
    let cursorDelta = jetstreamState.flatMap { stream -> Int64? in
      guard let received = stream.lastReceivedCursor, let committed = stream.lastCommittedCursor
      else { return nil }
      return max(0, received - committed)
    }
    let transportObservedAt = jetstreamState?.transportHeartbeatAt
    let transportValidUntil = transportObservedAt?.addingTimeInterval(config.idleAlertSeconds)
    let transportEvidenceCurrent = transportObservedAt != nil
      && (transportValidUntil.map { now < $0 } ?? false)
    let queueEvidence = jetstreamState?.queueEvidence
    let queueObservedAt = queueEvidence?.indexedThrough
    let queueEvidenceMissing = queueEvidence == nil || queueEvidence?.accuracy != .exact
      || queueObservedAt == nil
    let queueEvidenceExpired = !queueEvidenceMissing
      && (queueEvidence.map { now >= $0.validUntil } ?? false)
    let queueEvidenceCurrent = !queueEvidenceMissing && !queueEvidenceExpired
    let backlogObservedAt = [transportObservedAt, queueObservedAt].compactMap { $0 }.min()
    let backlogValidUntil = [transportValidUntil, queueEvidence?.validUntil]
      .compactMap { $0 }.min()
    let backlogEvidence: [String: String] = [
      "cursor_delta_microseconds": cursorDelta.map(String.init) ?? "unknown",
      "role": isAuthority ? "authority" : "supplemental_unverified",
      "transport_heartbeat_at": transportObservedAt?.ISO8601Format() ?? "none",
      "queue_observed_at": queueObservedAt?.ISO8601Format() ?? "none",
      "queue_depth": jetstreamState.map { String($0.queueDepth) } ?? "unknown",
      "queue_capacity": jetstreamState?.queueCapacity.map(String.init) ?? "unknown",
      "observedAt": backlogObservedAt?.ISO8601Format() ?? "none",
      "validUntil": backlogValidUntil?.ISO8601Format() ?? "none",
    ]
    let severity = isAuthority ? "critical" : "warning"
    try await reconcile(
      condition: queueEvidenceMissing,
      rule: "jetstream_queue_evidence_missing",
      conditionKey: "jetstream:queue_evidence_missing",
      severity: severity,
      summary: "No exact Jetstream processing-queue observation is available.",
      evidence: backlogEvidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)
    try await reconcile(
      condition: queueEvidenceExpired,
      rule: "jetstream_queue_evidence_expired",
      conditionKey: "jetstream:queue_evidence_expired",
      severity: severity,
      summary: "The Jetstream processing-queue observation has expired.",
      evidence: backlogEvidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)
    try await reconcile(
      condition: transportEvidenceCurrent && queueEvidenceCurrent
        && (cursorDelta.map { $0 >= config.backlogAlertMicroseconds } ?? false),
      rule: "jetstream_commit_backlog",
      conditionKey: "jetstream:commit_backlog",
      severity: severity,
      summary: "The measured Jetstream receive-to-commit backlog is above threshold.",
      evidence: backlogEvidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)
  }

  private func resolveLegacyJetstreamBacklogAlerts(at: Date) async throws {
    for conditionKey in [
      "jetstream:queue_evidence_missing",
      "jetstream:queue_evidence_expired",
      "jetstream:commit_backlog",
    ] {
      try await store.resolveAlert(conditionKey: conditionKey, at: at)
    }
  }

  private func evaluateTransport(
    source: String,
    state: IngestionStreamState?,
    isAuthority: Bool,
    at now: Date
  ) async throws {
    let displayName = source == "tap" ? "Tap" : (source == "jetstream" ? "Jetstream" : source)
    let role = isAuthority ? "authority" : "supplemental"
    let severity = isAuthority ? "critical" : "warning"
    let transportObservedAt = state?.transportHeartbeatAt
    let transportValidUntil = transportObservedAt?.addingTimeInterval(config.idleAlertSeconds)
    let evidence = [
      "transport_heartbeat_at": transportObservedAt?.ISO8601Format() ?? "none",
      "role": role,
      "observedAt": transportObservedAt?.ISO8601Format() ?? "none",
      "validUntil": transportValidUntil?.ISO8601Format() ?? "none",
    ]
    try await reconcile(
      condition: transportObservedAt == nil,
      rule: "\(source)_transport_evidence_missing",
      conditionKey: "\(source):transport_evidence_missing",
      severity: severity,
      summary: "No \(displayName) transport heartbeat evidence is available for the \(role) source.",
      evidence: evidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)

    let transportExpired = transportObservedAt.map {
      now.timeIntervalSince($0) >= config.idleAlertSeconds
    } ?? false
    try await reconcile(
      condition: transportExpired,
      rule: "\(source)_transport_heartbeat_expired",
      conditionKey: "\(source):transport_heartbeat_expired",
      severity: severity,
      summary: "The \(displayName) transport heartbeat has expired for the \(role) source.",
      evidence: evidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)

    let disconnected = state.map {
      $0.connectionState != .connected
        && now.timeIntervalSince($0.lastDisconnectAt ?? $0.transportHeartbeatAt ?? $0.heartbeatAt)
          >= config.disconnectAlertSeconds
    } ?? false
    try await reconcile(
      condition: disconnected,
      rule: "\(source)_disconnected",
      conditionKey: "\(source):transport_disconnected",
      severity: severity,
      summary: "\(displayName) has remained disconnected as the \(role) source.",
      evidence: evidence.merging([
        "connection_state": state?.connectionState.rawValue ?? "unknown",
      ]) { _, new in new },
      runbookSlug: source == "jetstream"
        ? "jetstream-disconnect-reconnect" : "tap-shadow-and-cutover",
      at: now)
  }

  private func resolveTransportAlerts(source: String, at: Date) async throws {
    for conditionKey in [
      "\(source):transport_evidence_missing",
      "\(source):transport_heartbeat_expired",
      "\(source):transport_disconnected",
    ] {
      try await store.resolveAlert(conditionKey: conditionKey, at: at)
    }
  }

  private func reconcile(
    condition: Bool,
    rule: String,
    conditionKey: String,
    severity: String,
    summary: String,
    evidence: [String: String],
    runbookSlug: String,
    at: Date
  ) async throws {
    if condition {
      _ = try await store.openAlert(
        rule: rule, conditionKey: conditionKey, severity: severity, summary: summary,
        evidence: evidence, runbookSlug: runbookSlug, at: at)
    } else {
      try await store.resolveAlert(conditionKey: conditionKey, at: at)
    }
  }

  private func evaluateMeasuredThresholds(at now: Date) async throws {
    let start = now.addingTimeInterval(-5 * 60)
    let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60 - 0.001)
    let results = try await store.listMetricRollups(
      startAt: start, endAt: end, metricName: "socialwire.ingestion.results_total",
      collection: nil, limit: 10_000)
    let totalResults = results.reduce(0.0) { $0 + $1.valueSum }
    let errorResults = results.filter { $0.dimensions["result"] == "error" }
      .reduce(0.0) { $0 + $1.valueSum }
    let enoughResults = totalResults >= Double(config.indexFailureMinimum)
    let failureRatio = totalResults > 0 ? errorResults / totalResults : 0
    try await reconcile(
      condition: enoughResults && failureRatio >= config.indexFailureRatio,
      rule: "index_failure_ratio",
      conditionKey: "ingestion:index_failure_ratio",
      severity: "critical",
      summary: "The measured ingestion failure ratio is above threshold.",
      evidence: [
        "sample_count": String(Int(totalResults)),
        "failure_ratio": String(failureRatio),
        "threshold": String(config.indexFailureRatio),
      ],
      runbookSlug: "live-process-stalled-ingestion",
      at: now)

    let requests = try await store.listMetricRollups(
      startAt: start, endAt: end, metricName: "socialwire.http.server.requests_total",
      collection: nil, limit: 10_000)
    let appViewRequests = requests.filter { $0.dimensions["service"] == "appview" }
    let totalRequests = appViewRequests.reduce(0.0) { $0 + $1.valueSum }
    let failures5xx = appViewRequests.filter { $0.dimensions["status_class"] == "5xx" }
      .reduce(0.0) { $0 + $1.valueSum }
    let enoughRequests = totalRequests >= Double(config.appView5xxMinimumRequests)
    let serverErrorRatio = totalRequests > 0 ? failures5xx / totalRequests : 0
    try await reconcile(
      condition: enoughRequests && serverErrorRatio >= config.appView5xxRatio,
      rule: "appview_5xx_ratio",
      conditionKey: "appview:http_5xx_ratio",
      severity: "critical",
      summary: "The measured AppView HTTP 5xx ratio is above threshold.",
      evidence: [
        "sample_count": String(Int(totalRequests)),
        "failure_ratio": String(serverErrorRatio),
        "threshold": String(config.appView5xxRatio),
      ],
      runbookSlug: "live-process-stalled-ingestion",
      at: now)
  }
}
