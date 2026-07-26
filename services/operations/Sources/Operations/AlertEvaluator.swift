import Foundation
import Logging
import OperationsCore

struct AlertEvaluator {
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
    let worker = services.filter { $0.service == "appview-worker" }
      .max(by: { $0.heartbeatAt < $1.heartbeatAt })
    let authoritySource: String?
    if let worker, now.timeIntervalSince(worker.heartbeatAt) <= 15,
      let advertised = worker.dependencyState["ingestion_authority"],
      ["jetstream", "tap"].contains(advertised)
    {
      authoritySource = advertised
    } else {
      authoritySource = nil
    }
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

    let streamStates = try await store.listStreamStates()
    let streamsBySource = Dictionary(uniqueKeysWithValues: streamStates.map { ($0.source, $0) })
    let tapRole = worker?.dependencyState["tap_role"]
    let tapEnabled = tapRole == "shadow" || tapRole == "authoritative"
    var evaluatedSources = Set(streamsBySource.keys.filter { $0 != "tap" })
    evaluatedSources.insert("jetstream")
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

    let jetstreamState = streamsBySource["jetstream"]
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
    let cursorDeltaValue = cursorDelta.map { String($0) } ?? "unknown"
    let role = authoritySource == "jetstream" ? "authority" : "supplemental_unverified"
    let transportHeartbeat = transportObservedAt?.ISO8601Format() ?? "none"
    let queueObserved = queueObservedAt?.ISO8601Format() ?? "none"
    let queueDepth = jetstreamState.map { String($0.queueDepth) } ?? "unknown"
    let queueCapacity = jetstreamState?.queueCapacity.map { String($0) } ?? "unknown"
    let backlogObserved = backlogObservedAt?.ISO8601Format() ?? "none"
    let backlogValid = backlogValidUntil?.ISO8601Format() ?? "none"
    let backlogEvidence: [String: String] = [
      "cursor_delta_microseconds": cursorDeltaValue,
      "role": role,
      "transport_heartbeat_at": transportHeartbeat,
      "queue_observed_at": queueObserved,
      "queue_depth": queueDepth,
      "queue_capacity": queueCapacity,
      "observedAt": backlogObserved,
      "validUntil": backlogValid,
    ]
    let jetstreamSeverity = authoritySource == "jetstream" ? "critical" : "warning"
    try await reconcile(
      condition: queueEvidenceMissing,
      rule: "jetstream_queue_evidence_missing",
      conditionKey: "jetstream:queue_evidence_missing",
      severity: jetstreamSeverity,
      summary: "No exact Jetstream processing-queue observation is available.",
      evidence: backlogEvidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)
    try await reconcile(
      condition: queueEvidenceExpired,
      rule: "jetstream_queue_evidence_expired",
      conditionKey: "jetstream:queue_evidence_expired",
      severity: jetstreamSeverity,
      summary: "The Jetstream processing-queue observation has expired.",
      evidence: backlogEvidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)
    try await reconcile(
      condition: transportEvidenceCurrent && queueEvidenceCurrent
        && (cursorDelta.map { $0 >= config.backlogAlertMicroseconds } ?? false),
      rule: "jetstream_commit_backlog",
      conditionKey: "jetstream:commit_backlog",
      severity: jetstreamSeverity,
      summary: "The measured Jetstream receive-to-commit backlog is above threshold.",
      evidence: backlogEvidence,
      runbookSlug: "live-process-stalled-ingestion",
      at: now)

    let counts = try await store.lifecycleCounts()
    try await reconcile(
      condition: counts.activeGaps > 0,
      rule: "active_ingestion_gap",
      conditionKey: "ingestion:active_gap",
      severity: "critical",
      summary: "An active ingestion gap requires investigation or recovery.",
      evidence: ["gap_count": String(counts.activeGaps)],
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
