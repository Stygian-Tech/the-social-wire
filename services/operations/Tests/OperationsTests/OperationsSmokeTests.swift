import Foundation
import Hummingbird
import Logging
import OperationsCore
import Testing

@testable import Operations

@Test("operations package resolves")
func operationsPackageResolves() {
  #expect(true)
}

@Test("Jetstream reconnect request does not require an operator reason")
func reconnectRequestDoesNotRequireReason() throws {
  let request = try JSONDecoder().decode(
    ReconnectJetstreamRequest.self,
    from: Data(#"{"idempotencyKey":"reconnect-1","expectedVersion":0}"#.utf8))

  #expect(request.environmentConfirmation == nil)
}

@Test("new event streams start at the current durable cursor")
func newEventStreamDoesNotReplayHistory() {
  let bounds = OperationsChangeEventCursorBounds(earliestAvailable: 40, latest: 900)

  #expect(OperationsRoutes.initialEventCursor(requested: nil, bounds: bounds) == 900)
  #expect(OperationsRoutes.initialEventCursor(requested: 875, bounds: bounds) == 875)
  #expect(bounds.canResume(after: 875))
  #expect(!bounds.canResume(after: 20))
  #expect(!bounds.canResume(after: 901))
}

@Test("event cursors reject expired and future positions while preserving valid starts")
func eventStreamCursorBoundsAreEnforced() throws {
  let bounds = OperationsChangeEventCursorBounds(earliestAvailable: 40, latest: 900)
  #expect(try OperationsRoutes.eventStreamCursor(requested: nil, bounds: bounds) == 900)
  #expect(try OperationsRoutes.eventStreamCursor(requested: 875, bounds: bounds) == 875)
  #expect(try OperationsRoutes.eventStreamCursor(requested: 900, bounds: bounds) == 900)
  do {
    _ = try OperationsRoutes.eventStreamCursor(requested: 20, bounds: bounds)
    Issue.record("Expected an expired SSE cursor to be rejected")
  } catch let error as HTTPError {
    #expect(error.status == .gone)
  }
  for parsed in [
    try OperationsRoutes.eventCursor(queryValue: "901", lastEventID: nil),
    try OperationsRoutes.eventCursor(queryValue: nil, lastEventID: "901"),
  ] {
    do {
      _ = try OperationsRoutes.eventStreamCursor(requested: parsed, bounds: bounds)
      Issue.record("Expected a future SSE cursor to be rejected")
    } catch let error as HTTPError {
      #expect(error.status == .badRequest)
    }
  }
  #expect(try OperationsRoutes.eventCursor(queryValue: nil, lastEventID: nil) == nil)
  #expect(try OperationsRoutes.eventCursor(queryValue: "900", lastEventID: "901") == 900)
}

@Test("recovery modes use exact worker-advertised capability evidence")
func recoveryCapabilitiesAreIndependent() async throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("operations-capability-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: url) }
  let store = try SQLiteOperationsStore(
    path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
  let now = Date()
  try await store.upsertServiceState(OperationsServiceState(
    service: "appview-worker", environment: "dev", instanceId: "worker-1",
    liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .unknown,
    dependencyState: [
      "operations_database": "ready", "appview_database": "ready",
      "jetstream_replay": "enabled_unverified", "pds_reconciliation": "disabled",
    ],
    startedAt: now, heartbeatAt: now))
  let config = OperationsConfiguration.fromEnvironment([
    "APP_ENV": "dev", "OPERATIONS_RECOVERY_ENABLED": "true",
    "OPERATIONS_BACKFILL_FINGERPRINT_SECRET": "test-secret",
  ])

  let capabilities = await OperationsCapabilityResolver(store: store, config: config)
    .resolve(at: now)

  #expect(capabilities.recovery.enabled)
  #expect(capabilities.recoveryModes.jetstreamReplay.enabled)
  #expect(!capabilities.recoveryModes.pdsReconciliation.enabled)
  #expect(
    capabilities.recoveryModes.pdsReconciliation.disabledReason
      == "PDS reconciliation is unavailable: disabled.")
}

@Test("malformed pagination cursors are rejected at the HTTP boundary")
func malformedPaginationCursorIsBadRequest() throws {
  #expect(try OperationsRoutes.paginationCursor(nil) == nil)
  #expect(throws: HTTPError.self) {
    _ = try OperationsRoutes.paginationCursor("not-a-cursor")
  }
  let cursor = OperationsPaginationCursor.encode(date: Date(), id: "record-1")
  #expect(try OperationsRoutes.paginationCursor(cursor) == cursor)
}

@Test("recovery collection scopes are normalized and allowlisted per source")
func recoveryCollectionScopesAreServerEnforced() throws {
  let normalized = try OperationsRoutes.validate(BackfillDryRunRequest(
    sourceMode: .jetstreamReplay,
    startCursor: 1,
    endCursor: 2,
    collections: [" app.skyreader.feed.subscription ", "site.standard.document"],
    batchSize: 100,
    rateLimit: 50,
    maxConcurrency: 1))
  #expect(normalized.collections == ["app.skyreader.feed.subscription", "site.standard.document"])

  for rejectedCollections in [
    ["site.standard.document", " site.standard.document "],
    ["com.standard.document"],
    ["app.bsky.graph.follow"],
    ["app.thesocialwire.entryReadState"],
  ] {
    #expect(throws: HTTPError.self) {
      _ = try OperationsRoutes.validate(BackfillDryRunRequest(
        sourceMode: .jetstreamReplay,
        startCursor: 1,
        endCursor: 2,
        collections: rejectedCollections,
        batchSize: 100,
        rateLimit: 50,
        maxConcurrency: 1))
    }
  }

  #expect(throws: HTTPError.self) {
    _ = try OperationsRoutes.validate(BackfillDryRunRequest(
      sourceMode: .tapVerifiedResync,
      collections: ["app.skyreader.feed.subscription"],
      authorDids: ["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"],
      batchSize: 100,
      rateLimit: 50,
      maxConcurrency: 1))
  }
}

@Test("ingestion evidence never substitutes content heartbeat for transport heartbeat")
func ingestionEvidenceUsesOnlyTransportHeartbeat() {
  let now = Date()
  let worker = OperationsServiceState(
    service: "appview-worker", environment: "dev", instanceId: "worker-1",
    liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
    dependencyState: ["ingestion_authority": "jetstream"],
    startedAt: now, heartbeatAt: now)
  let contentOnly = IngestionStreamState(
    environment: "dev", source: "jetstream", connectionState: .connected,
    heartbeatAt: now)
  let unavailable = OperationsEvidenceResolver.ingestionAuthority(
    services: [worker], streams: [contentOnly], at: now)
  #expect(unavailable.state?.source == "jetstream")
  #expect(unavailable.evidence.accuracy == .unavailable)
  #expect(unavailable.evidence.indexedThrough == nil)
  #expect(unavailable.evidence.coverage == 0)

  let transportAt = now.addingTimeInterval(-2)
  let measured = IngestionStreamState(
    environment: "dev", source: "jetstream", connectionState: .connected,
    transportHeartbeatAt: transportAt, heartbeatAt: now)
  let current = OperationsEvidenceResolver.ingestionAuthority(
    services: [worker], streams: [measured], at: now)
  #expect(current.evidence.accuracy == .exact)
  #expect(current.evidence.indexedThrough == transportAt)
  #expect(current.evidence.coverage == 1)
}

@Test("route evidence uses required service peers and the advertised ingestion authority")
func routeEvidenceUsesRequiredPeersAndAuthority() {
  let now = Date(timeIntervalSince1970: 2_000)
  let staleAt = now.addingTimeInterval(-90)
  let services = [
    OperationsServiceState(
      service: "gateway", environment: "dev", instanceId: "gateway-1",
      liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
      dependencyState: [:], startedAt: staleAt, heartbeatAt: now),
    OperationsServiceState(
      service: "appview", environment: "dev", instanceId: "appview-1",
      liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
      dependencyState: [:], startedAt: staleAt, heartbeatAt: staleAt),
    OperationsServiceState(
      service: "appview-worker", environment: "dev", instanceId: "worker-1",
      liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
      dependencyState: ["ingestion_authority": "tap"],
      startedAt: staleAt, heartbeatAt: now),
  ]
  let allServices = OperationsEvidenceResolver.services(services, at: now)
  #expect(allServices.accuracy == .sampled)
  #expect(allServices.coverage == 0.5)
  #expect(allServices.indexedThrough == staleAt)
  #expect(allServices.degradedReason?.contains("appview, operations") == true)

  let appView = OperationsEvidenceResolver.services(
    services.filter { $0.service == "gateway" || $0.service == "appview" },
    requiredServices: ["gateway", "appview"], source: "operations_service_state.appview",
    at: now)
  #expect(appView.accuracy == .sampled)
  #expect(appView.coverage == 0.5)
  #expect(appView.indexedThrough == staleAt)

  let jetstreamAt = now.addingTimeInterval(-1)
  let tapAt = now.addingTimeInterval(-4)
  let streams = [
    IngestionStreamState(
      environment: "dev", source: "jetstream", connectionState: .connected,
      transportHeartbeatAt: jetstreamAt, heartbeatAt: jetstreamAt),
    IngestionStreamState(
      environment: "dev", source: "tap", connectionState: .connected,
      transportHeartbeatAt: tapAt, heartbeatAt: tapAt),
  ]
  let authority = OperationsEvidenceResolver.ingestionAuthority(
    services: services, streams: streams, at: now)
  #expect(authority.state?.source == "tap")
  #expect(authority.evidence.indexedThrough == tapAt)
  #expect(authority.evidence.ageSeconds == 4)

  let staleAuthority = OperationsEvidenceResolver.ingestionAuthority(
    services: services, streams: streams, at: now.addingTimeInterval(60))
  #expect(staleAuthority.state == nil)
  #expect(staleAuthority.evidence.accuracy == .unavailable)
  #expect(staleAuthority.evidence.indexedThrough == nil)
}

@Test("trace evidence freshness is derived from the latest observed span")
func traceEvidenceUsesSpanWatermark() {
  let generatedAt = Date(timeIntervalSince1970: 1_000)
  let latestSpanAt = generatedAt.addingTimeInterval(-120)
  let spans = [
    TraceSpan(
      environment: "dev", traceId: "trace-1", service: "operations", name: "GET /health",
      startedAt: latestSpanAt.addingTimeInterval(-30), durationMs: 2, status: "ok",
      attributes: [:], expiresAt: generatedAt.addingTimeInterval(60)),
    TraceSpan(
      environment: "dev", traceId: "trace-2", service: "operations", name: "GET /overview",
      startedAt: latestSpanAt, durationMs: 5, status: "ok", attributes: [:],
      expiresAt: generatedAt.addingTimeInterval(60)),
  ]

  let stale = OperationsRoutes.traceEvidence(
    spans, totalCount: 4, truncated: true, generatedAt: generatedAt,
    emptyReason: "No traces exist in the requested range.")
  #expect(stale.accuracy == .sampled)
  #expect(stale.indexedThrough == latestSpanAt)
  #expect(stale.ageSeconds == 120)
  #expect(stale.validUntil == latestSpanAt.addingTimeInterval(75))
  #expect(stale.lastSuccessfulAt == latestSpanAt)
  #expect(stale.coverage == 0.5)
  #expect(stale.validUntil < generatedAt)

  let unavailable = OperationsRoutes.traceEvidence(
    [], totalCount: 0, truncated: false, generatedAt: generatedAt,
    emptyReason: "No traces exist in the requested range.")
  #expect(unavailable.accuracy == .unavailable)
  #expect(unavailable.indexedThrough == nil)
  #expect(unavailable.ageSeconds == 0)
  #expect(unavailable.validUntil == generatedAt)
  #expect(unavailable.lastSuccessfulAt == nil)
  #expect(unavailable.coverage == 0)
}

@Test("an observed empty lifecycle page remains an exact zero")
func observedEmptyLifecycleEvidenceIsExact() {
  let observedAt = Date(timeIntervalSince1970: 3_000)
  let empty = OperationsRoutes.evidence(
    source: "appview_ingestion_gaps.active", itemCount: 0, totalCount: 0,
    indexedThrough: observedAt, validitySeconds: 5,
    emptyReason: "No active gaps exist.", generatedAt: observedAt)
  #expect(empty.accuracy == .exact)
  #expect(empty.indexedThrough == observedAt)
  #expect(empty.coverage == 1)
  #expect(empty.degradedReason == nil)

  let unavailable = OperationsRoutes.evidence(
    source: "appview_jetstream_endpoints", itemCount: 0, totalCount: 0,
    indexedThrough: nil, validitySeconds: 45,
    emptyReason: "No endpoint observations exist.", generatedAt: observedAt)
  #expect(unavailable.accuracy == .unavailable)
  #expect(unavailable.coverage == 0)
  #expect(unavailable.degradedReason == "No endpoint observations exist.")
}

@Test("Tap transport alerts only exist while Tap is explicitly enabled")
func tapAlertsFollowAdvertisedRole() async throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("operations-alert-role-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: url) }
  let store = try SQLiteOperationsStore(
    path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
  let config = OperationsConfiguration.fromEnvironment(["APP_ENV": "dev"])
  let evaluator = AlertEvaluator(
    store: store, config: config, logger: Logger(label: "operations.test"), webhook: nil)
  let now = Date()

  try await store.upsertServiceState(OperationsServiceState(
    service: "appview-worker", environment: "dev", instanceId: "worker-1",
    liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .unknown,
    dependencyState: ["ingestion_authority": "jetstream"],
    startedAt: now, heartbeatAt: now))
  try await evaluator.evaluate(at: now)
  #expect(try await store.listAlerts(view: .all, limit: 250, before: nil).items
    .allSatisfy { !$0.conditionKey.hasPrefix("tap:") })

  try await store.upsertServiceState(OperationsServiceState(
    service: "appview-worker", environment: "dev", instanceId: "worker-1",
    liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .unknown,
    dependencyState: ["ingestion_authority": "jetstream", "tap_role": "shadow"],
    startedAt: now, heartbeatAt: now.addingTimeInterval(1)))
  try await evaluator.evaluate(at: now.addingTimeInterval(1))
  #expect(try await store.listAlerts(view: .active, limit: 250, before: nil).items
    .contains { $0.conditionKey == "tap:transport_evidence_missing" })

  try await store.upsertServiceState(OperationsServiceState(
    service: "appview-worker", environment: "dev", instanceId: "worker-1",
    liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .unknown,
    dependencyState: ["ingestion_authority": "jetstream", "tap_role": "disabled"],
    startedAt: now, heartbeatAt: now.addingTimeInterval(2)))
  try await evaluator.evaluate(at: now.addingTimeInterval(2))
  #expect(try await store.listAlerts(view: .active, limit: 250, before: nil).items
    .allSatisfy { !$0.conditionKey.hasPrefix("tap:") })
  #expect(try await store.listAlerts(view: .history, limit: 250, before: nil).items
    .contains { $0.conditionKey == "tap:transport_evidence_missing" })
}

@Test("Jetstream backlog alerts require current transport and queue evidence")
func jetstreamBacklogRequiresCurrentEvidence() async throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("operations-alert-backlog-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: url) }
  let store = try SQLiteOperationsStore(
    path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
  let config = OperationsConfiguration.fromEnvironment([
    "APP_ENV": "dev", "OPERATIONS_BACKLOG_ALERT_MICROSECONDS": "10",
    "OPERATIONS_IDLE_ALERT_SECONDS": "300",
  ])
  let evaluator = AlertEvaluator(
    store: store, config: config, logger: Logger(label: "operations.test"), webhook: nil)
  let now = Date()

  try await store.upsertServiceState(OperationsServiceState(
    service: "appview-worker", environment: "dev", instanceId: "worker-1",
    liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .unknown,
    dependencyState: ["ingestion_authority": "jetstream"],
    startedAt: now, heartbeatAt: now))
  try await store.markStreamReceived(
    source: "jetstream", cursor: 100, eventAt: now, receivedAt: now, queueDepth: 1)
  try await store.markStreamCommitted(
    source: "jetstream", cursor: 1, eventAt: now, committedAt: now, queueDepth: 1)
  try await store.markStreamTransportHeartbeat(source: "jetstream", at: now)
  try await store.recordStreamQueueObservation(
    source: "jetstream", depth: 1, capacity: 256, overflowTotal: 0, observedAt: now)

  try await evaluator.evaluate(at: now)
  let active = try await store.listAlerts(view: .active, limit: 250, before: nil).items
  let backlog = try #require(active.first { $0.conditionKey == "jetstream:commit_backlog" })
  #expect(backlog.evidence["cursor_delta_microseconds"] == "99")
  #expect(backlog.evidence["role"] == "authority")
  #expect(backlog.evidence["queue_depth"] == "1")
  #expect(backlog.evidence["queue_capacity"] == "256")
  #expect(backlog.evidence["observedAt"] == now.ISO8601Format())
  #expect(backlog.evidence["validUntil"] == now.addingTimeInterval(15).ISO8601Format())

  let expiredAt = now.addingTimeInterval(20)
  try await store.upsertServiceState(OperationsServiceState(
    service: "appview-worker", environment: "dev", instanceId: "worker-1",
    liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .unknown,
    dependencyState: ["ingestion_authority": "jetstream"],
    startedAt: now, heartbeatAt: expiredAt))
  try await evaluator.evaluate(at: expiredAt)
  let afterExpiry = try await store.listAlerts(view: .active, limit: 250, before: nil).items
  #expect(afterExpiry.allSatisfy { $0.conditionKey != "jetstream:commit_backlog" })
  #expect(afterExpiry.contains { $0.conditionKey == "jetstream:queue_evidence_expired" })
  #expect(try await store.listAlerts(view: .history, limit: 250, before: nil).items
    .contains { $0.conditionKey == "jetstream:commit_backlog" })
}

@Test("one durable webhook attempt performs exactly one HTTP request")
func webhookDeliveryDoesNotNestRetries() async throws {
  actor AttemptCounter {
    private(set) var value = 0
    func increment() { value += 1 }
  }
  let counter = AttemptCounter()
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("operations-webhook-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: url) }
  let store = try SQLiteOperationsStore(
    path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
  let alert = try await store.openAlert(
    rule: "test", conditionKey: "test:webhook", severity: "warning", summary: "Test",
    evidence: [:], runbookSlug: "test", at: Date())
  let delivery = OperationsWebhookDelivery(
    url: "https://alerts.invalid", secret: "secret", logger: Logger(label: "operations.test")
  ) { _ in
    await counter.increment()
    return 503
  }

  await #expect(throws: WebhookDeliveryError.self) {
    try await delivery.deliver(alert)
  }
  #expect(await counter.value == 1)
}

@Test("disabled telemetry cannot report healthy observability freshness or completeness")
func disabledTelemetryIsUnknown() {
  let snapshot = OperationsTelemetryBufferSnapshot(
    queueDepth: 0, inFlightCount: 0, capacity: 4_096, droppedCount: 0,
    consecutiveFailures: 0, lastSuccessfulExportAt: nil)
  let disabled = OperationsCommand.telemetryHealth(enabled: false, snapshot: snapshot)
  #expect(disabled.freshness == .unknown)
  #expect(disabled.completeness == .unknown)

  let enabled = OperationsCommand.telemetryHealth(enabled: true, snapshot: snapshot)
  #expect(enabled.freshness == .healthy)
  #expect(enabled.completeness == .healthy)
}
