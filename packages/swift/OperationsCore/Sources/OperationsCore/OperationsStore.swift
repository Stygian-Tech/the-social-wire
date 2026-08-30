import Foundation

public protocol OperationsStore: Actor {
  func ping() async throws
  func fetchDatabaseObservability() async throws -> DatabaseObservabilitySnapshot?
  func fetchViewerCounts(at: Date) async throws -> OperationsViewerCounts?
  func upsertServiceState(_ state: OperationsServiceState) async throws
  func listServiceStates() async throws -> [OperationsServiceState]

  func fetchStreamState(source: String) async throws -> IngestionStreamState?
  func listStreamStates() async throws -> [IngestionStreamState]
  func markStreamConnected(source: String, at: Date) async throws
  func markStreamTransportHeartbeat(source: String, at: Date) async throws
  func markStreamDisconnected(source: String, reason: String, at: Date) async throws
  func recordStreamQueueObservation(
    source: String, depth: Int, capacity: Int, overflowTotal: Int64, observedAt: Date
  ) async throws
  func markStreamIndexedMutation(source: String, at: Date) async throws
  func markStreamProjectionWatermark(source: String, watermark: String, at: Date) async throws
  func markStreamValidationWatermark(source: String, watermark: String, at: Date) async throws
  func upsertJetstreamEndpoint(_ state: JetstreamEndpointState) async throws
  func listJetstreamEndpoints() async throws -> [JetstreamEndpointState]
  func listJetstreamEndpoints(limit: Int, before: String?) async throws
    -> OperationsPage<JetstreamEndpointState>
  func markStreamReceived(
    source: String, cursor: Int64, eventAt: Date?, receivedAt: Date, queueDepth: Int) async throws
  func markStreamCommitted(
    source: String, cursor: Int64, eventAt: Date?, committedAt: Date, queueDepth: Int) async throws
  func recordRecoveryFailure(
    jobId: String?, identityHash: String, collection: String, operation: String, cursor: Int64?,
    errorCategory: String, at: Date) async throws

  func fetchIngestionDurabilitySnapshot(at: Date) async throws -> IngestionDurabilitySnapshot
  func listIngestionIncidents(limit: Int, before: String?) async throws
    -> OperationsPage<IngestionIncident>
  func upsertOrMergeActiveIncident(
    _ candidate: IngestionIncidentCandidate, legacyGapId: String?
  ) async throws -> IngestionIncident
  func acquireIngestionLeaderLease(
    name: String, sourceGeneration: String, ownerID: String, leaseUntil: Date, at: Date
  ) async throws -> IngestionLeaderLease?
  func renewIngestionLeaderLease(
    name: String, ownerID: String, fencingToken: Int64, leaseUntil: Date, at: Date
  ) async throws -> IngestionLeaderLease
  func releaseIngestionLeaderLease(
    name: String, ownerID: String, fencingToken: Int64, at: Date
  ) async throws
  /// Holds the durable lease row fence for one authority-owned operation. A takeover cannot
  /// complete until the operation returns; a stale owner never enters the operation.
  func withIngestionLeaderLeaseFence(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws

  func acquireRoleLease(
    role: String, ownerID: String, leaseUntil: Date, at: Date
  ) async throws -> FencedRoleLease?
  func renewRoleLease(
    role: String, ownerID: String, fencingToken: Int64, leaseUntil: Date, at: Date
  ) async throws -> FencedRoleLease
  func releaseRoleLease(
    role: String, ownerID: String, fencingToken: Int64, at: Date
  ) async throws
  /// Holds the role row fence for one singleton operation. A takeover cannot complete until the
  /// operation returns, and an owner with a stale fencing token never enters the operation.
  func withRoleLeaseFence(
    role: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws

  func createCommand(
    action: OperationsCommandAction, operatorDid: String, auditNote: String, at: Date
  ) async throws -> OperationsWorkerCommand
  func createCommand(
    action: OperationsCommandAction, operatorDid: String, auditNote: String?,
    expectedStreamVersion: Int, idempotencyKey: String, requestId: String?, at: Date
  ) async throws -> OperationsWorkerCommand
  func listCommands(limit: Int) async throws -> [OperationsWorkerCommand]
  func listCommands(limit: Int, before: String?) async throws
    -> OperationsPage<OperationsWorkerCommand>
  func claimNextCommand(
    action: OperationsCommandAction, workerId: String, at: Date
  ) async throws -> OperationsWorkerCommand?
  func completeCommand(
    id: String, status: OperationsCommandStatus, failureReason: String?, workerId: String,
    expectedVersion: Int, requestId: String?, note: String?, at: Date
  ) async throws -> OperationsWorkerCommand

  func createGap(
    source: String, startCursor: Int64?, endCursor: Int64?, reason: String, collections: [String],
    detectedAt: Date
  ) async throws -> IngestionGap
  func listGaps(limit: Int) async throws -> [IngestionGap]
  func fetchGap(id: String) async throws -> IngestionGap?
  func listGaps(view: GapListView, limit: Int, before: String?) async throws
    -> OperationsPage<IngestionGap>
  func lifecycleCounts() async throws -> OperationsLifecycleCounts
  func updateGap(id: String, status: IngestionGapStatus, operatorDid: String, at: Date) async throws
  func transitionGap(
    id: String, to status: IngestionGapStatus, expectedVersion: Int, operatorDid: String,
    idempotencyKey: String, requestId: String?, note: String?, at: Date
  ) async throws -> IngestionGap
  func resolveSuspectedGaps(source: String, through committedCursor: Int64, at: Date) async throws
    -> [String]

  func estimateBackfill(_ request: BackfillDryRunRequest) async throws -> BackfillDryRunResponse
  func createBackfill(
    _ request: CreateBackfillRequest, operatorDid: String, requestId: String?, at: Date
  ) async throws
    -> BackfillJob
  func listBackfills(limit: Int) async throws -> [BackfillJob]
  func listBackfills(view: BackfillListView, limit: Int, before: String?) async throws
    -> OperationsPage<BackfillJob>
  func fetchBackfill(id: String) async throws -> BackfillJob?
  func updateBackfillStatus(
    id: String,
    status: BackfillJobStatus,
    operatorDid: String,
    failureReason: String?,
    at: Date
  ) async throws
  func transitionBackfill(
    id: String, to status: BackfillJobStatus, expectedVersion: Int, operatorDid: String,
    idempotencyKey: String, requestId: String?, note: String?, failureReason: String?, at: Date
  ) async throws -> BackfillJob
  func claimNextBackfill(workerId: String, leaseUntil: Date, at: Date) async throws -> BackfillJob?
  func renewBackfillLease(
    id: String, workerId: String, expectedVersion: Int, leaseUntil: Date, at: Date
  ) async throws -> BackfillJob
  func recordBackfillVerification(
    id: String, workerId: String, expectedVersion: Int, exactScope: Bool, truncated: Bool,
    failedCount: Int, validationWatermark: String?, at: Date
  ) async throws -> BackfillJob
  func recordBackfillAuthorResults(
    id: String, workerId: String, expectedVersion: Int, results: [BackfillAuthorResult], at: Date
  ) async throws -> BackfillJob
  func checkpointBackfill(
    id: String, workerId: String, expectedVersion: Int, cursor: Int64?, processed: Int,
    failed: Int, reconciled: Int, leaseUntil: Date, at: Date
  ) async throws -> BackfillJob
  func checkpointBackfill(
    id: String, cursor: Int64?, processed: Int, failed: Int, reconciled: Int, leaseUntil: Date,
    at: Date) async throws

  func listAlerts(limit: Int) async throws -> [OperationsAlert]
  func listAlerts(limit: Int, before: String?) async throws -> OperationsPage<OperationsAlert>
  func listAlerts(view: AlertListView, limit: Int, before: String?) async throws
    -> OperationsPage<OperationsAlert>
  func fetchAlert(id: String) async throws -> OperationsAlert?
  func openAlert(
    rule: String, conditionKey: String, severity: String, summary: String, evidence: [String: String],
    runbookSlug: String, at: Date
  ) async throws -> OperationsAlert
  func resolveAlert(conditionKey: String, at: Date) async throws
  func listAlertsPendingDelivery(limit: Int, at: Date) async throws -> [OperationsAlert]
  func retryAlertDelivery(
    id: String, expectedVersion: Int, operatorDid: String, idempotencyKey: String,
    requestId: String?, note: String?, at: Date
  ) async throws -> OperationsAlert
  func updateAlertStatus(id: String, status: OperationsAlertStatus, operatorDid: String, at: Date)
    async throws
  func transitionAlert(
    id: String, to status: OperationsAlertStatus, expectedVersion: Int, operatorDid: String,
    idempotencyKey: String, requestId: String?, note: String?, at: Date
  ) async throws -> OperationsAlert
  func recordAlertDelivery(id: String, error: String?, at: Date) async throws
  func listTraceSpans(limit: Int, traceId: String?) async throws -> [TraceSpan]
  func listTraceSpans(startAt: Date, endAt: Date, limit: Int) async throws -> [TraceSpan]
  func listTraceSpans(startAt: Date, endAt: Date, limit: Int, before: String?) async throws
    -> OperationsPage<TraceSpan>
  func recordTraceSpan(_ span: TraceSpan) async throws
  func recordMetric(_ sample: OperationsMetricSample) async throws
  func recordTelemetryBatch(_ signals: [OperationsTelemetrySignal]) async throws
  func listMetricRollups(startAt: Date, endAt: Date, limit: Int) async throws
    -> [OperationsMetricRollup]
  func listMetricRollups(
    startAt: Date, endAt: Date, metricName: String?, collection: String?, limit: Int
  ) async throws -> [OperationsMetricRollup]
  func listGapInvestigationEvents(startAt: Date, endAt: Date, limit: Int) async throws
    -> [OperationsEvent]
  func recordEvent(_ event: OperationsEvent) async throws
  func appendChangeEvent(
    eventType: String, entityType: String, entityId: String?, payload: [String: String], at: Date
  ) async throws -> OperationsChangeEvent
  func listChangeEvents(after cursor: Int64, limit: Int) async throws -> [OperationsChangeEvent]
  func changeEventCursorBounds() async throws -> OperationsChangeEventCursorBounds
  func recordAudit(
    operatorDid: String, action: String, targetType: String, targetId: String?, note: String?,
    at: Date) async throws
  func recordAudit(_ audit: OperationsMutationAudit) async throws
  func cleanupExpired(at: Date, batchSize: Int) async throws -> Int
}

extension OperationsStore {
  public func fetchDatabaseObservability() async throws -> DatabaseObservabilitySnapshot? { nil }

  public func fetchViewerCounts(at: Date) async throws -> OperationsViewerCounts? { nil }

  // Keep lightweight/test stores source-compatible while durable ingestion is rolled out.
  // Production stores override these methods with the provider-specific implementation.
  public func fetchIngestionDurabilitySnapshot(at: Date) async throws
    -> IngestionDurabilitySnapshot
  {
    throw OperationsStoreError.notFound
  }

  public func listIngestionIncidents(limit: Int, before: String?) async throws
    -> OperationsPage<IngestionIncident>
  {
    throw OperationsStoreError.notFound
  }

  public func upsertOrMergeActiveIncident(
    _ candidate: IngestionIncidentCandidate, legacyGapId: String?
  ) async throws -> IngestionIncident {
    throw OperationsStoreError.notFound
  }

  public func acquireIngestionLeaderLease(
    name: String, sourceGeneration: String, ownerID: String, leaseUntil: Date, at: Date
  ) async throws -> IngestionLeaderLease? {
    throw OperationsStoreError.notFound
  }

  public func renewIngestionLeaderLease(
    name: String, ownerID: String, fencingToken: Int64, leaseUntil: Date, at: Date
  ) async throws -> IngestionLeaderLease {
    throw OperationsStoreError.notFound
  }

  public func releaseIngestionLeaderLease(
    name: String, ownerID: String, fencingToken: Int64, at: Date
  ) async throws {
    throw OperationsStoreError.notFound
  }

  public func withIngestionLeaderLeaseFence(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    throw OperationsStoreError.notFound
  }

  public func acquireRoleLease(
    role: String, ownerID: String, leaseUntil: Date, at: Date
  ) async throws -> FencedRoleLease? {
    throw OperationsStoreError.notFound
  }

  public func renewRoleLease(
    role: String, ownerID: String, fencingToken: Int64, leaseUntil: Date, at: Date
  ) async throws -> FencedRoleLease {
    throw OperationsStoreError.notFound
  }

  public func releaseRoleLease(
    role: String, ownerID: String, fencingToken: Int64, at: Date
  ) async throws {
    throw OperationsStoreError.notFound
  }

  public func withRoleLeaseFence(
    role: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    throw OperationsStoreError.notFound
  }

  public func recordTelemetryBatch(_ signals: [OperationsTelemetrySignal]) async throws {
    for signal in signals {
      switch signal {
      case .metric(let sample): try await recordMetric(sample)
      case .event(let event): try await recordEvent(event)
      case .span(let span): try await recordTraceSpan(span)
      }
    }
  }

  public func overview(
    at: Date = Date(),
    capabilities: OperationsCapabilities? = nil
  ) async throws -> OperationsOverview {
    async let services = listServiceStates()
    async let streamStates = listStreamStates()
    async let database = fetchDatabaseObservability()
    async let viewers = fetchViewerCounts(at: at)
    async let counts = lifecycleCounts()
    let resolvedServices = try await services
    let resolvedStreamStates = try await streamStates
    let resolvedCounts = try await counts
    let serviceEvidence = OperationsEvidenceResolver.services(resolvedServices, at: at)
    let durability = try? await fetchIngestionDurabilitySnapshot(at: at)
    let ingestion = OperationsEvidenceResolver.ingestionAuthority(
      services: resolvedServices,
      streams: resolvedStreamStates,
      durability: durability,
      at: at)
    let databaseSnapshot = try? await database
    let viewerCounts = try? await viewers
    var evidence: [String: OperationsEvidenceMetadata] = [
      "services": serviceEvidence,
      "ingestion": ingestion.evidence,
    ]
    let databaseObservedAt = databaseSnapshot?.observedAt
    evidence["database"] = OperationsEvidenceMetadata(
      source: "pg_stat_database", accuracy: databaseSnapshot == nil ? .unavailable : .estimated,
      generatedAt: at, indexedThrough: databaseObservedAt,
      ageSeconds: databaseObservedAt.map { max(0, at.timeIntervalSince($0)) } ?? 0,
      validUntil: databaseObservedAt?.addingTimeInterval(60) ?? at,
      coverage: databaseSnapshot == nil ? 0 : 1,
      lastSuccessfulAt: databaseObservedAt,
      degradedReason: databaseSnapshot == nil ? "Database observability query failed." : nil)
    return OperationsOverview(
      services: resolvedServices,
      ingestion: ingestion.state,
      ingestionSources: resolvedStreamStates,
      jetstreamEndpoints: [],
      commands: [],
      gaps: [],
      backfills: [],
      alerts: [],
      recentTraces: [],
      metricRollups: [],
      database: databaseSnapshot,
      refreshedAt: at,
      evidence: evidence,
      capabilities: capabilities,
      counts: resolvedCounts,
      viewers: viewerCounts ?? nil,
      durability: durability
    )
  }
}
