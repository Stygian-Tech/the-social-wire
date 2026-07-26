export type Health = "healthy" | "degraded" | "unhealthy" | "unknown"
export type EvidenceAccuracy = "exact" | "sampled" | "estimated" | "unavailable"
export type EnvironmentName = "dev" | "prod"
export type EvidenceEnvelope = {
  source: string
  accuracy: EvidenceAccuracy
  generatedAt: string
  indexedThrough?: string
  ageSeconds: number
  validUntil: string
  coverage?: number
  lastSuccessfulAt?: string
  degradedReason?: string
}
export type OverviewEvidence = Record<string, EvidenceEnvelope> & {
  services: EvidenceEnvelope
  ingestion: EvidenceEnvelope
  database: EvidenceEnvelope
}
export type Capability = {
  enabled: boolean
  disabledReason?: string
}
export type RecoveryModeCapabilities = {
  tapVerifiedResync: Capability
  jetstreamReplay: Capability
  pdsReconciliation: Capability
}
export type OperationsCapabilities = {
  environment: EnvironmentName
  telemetry: Capability
  recovery: Capability
  recoveryModes: RecoveryModeCapabilities
  alertDelivery: Capability
  generatedAt: string
  eventStream: Capability & {
    path: string
    retryMilliseconds: number
    fallbackPollMilliseconds: number
  }
}
export type OperationsCounts = {
  activeGaps: number
  activeBackfills: number
  attentionBackfills: number
  completedBackfills: number
  unresolvedAlerts: number
}
export type ServiceState = {
  service: string
  environment: EnvironmentName
  instanceId: string
  liveness: Health
  readiness: Health
  freshness: Health
  completeness: Health
  dependencyState: Record<string, string>
  version?: string
  startedAt: string
  heartbeatAt: string
}
export type StreamState = {
  source: string
  connectionState: "connected" | "disconnected" | "reconnecting" | "unknown"
  connectedAt?: string
  lastDisconnectAt?: string
  lastDisconnectReason?: string
  lastReceivedCursor?: number
  lastReceivedEventAt?: string
  lastReceivedAt?: string
  lastCommittedCursor?: number
  lastCommittedEventAt?: string
  lastCommittedAt?: string
  queueDepth: number
  queueCapacity?: number
  queueOverflowTotal?: number
  queueEvidence?: EvidenceEnvelope
  transportHeartbeatAt?: string
  lastIndexedMutationAt?: string
  projectionWatermark?: string
  validationWatermark?: string
  heartbeatAt: string
  version: number
  environment: EnvironmentName
}
export type JetstreamEndpoint = {
  id: string
  displayName: string
  host: string
  role: "active" | "standby"
  connectionState: "connected" | "disconnected" | "reconnecting" | "unknown"
  lastConnectedAt?: string
  lastDisconnectedAt?: string
  lastError?: string
  connectionAttempts: number
  failoverCount: number
  updatedAt: string
  version: number
  environment: EnvironmentName
}
export type OperationsCommand = {
  id: string
  action: "reconnect_jetstream"
  status: "queued" | "running" | "completed" | "failed"
  requestedByDid: string
  auditNote?: string
  claimedBy?: string
  leaseExpiresAt?: string
  failureReason?: string
  createdAt: string
  updatedAt: string
  completedAt?: string
  version: number
  environment: EnvironmentName
}
export type Gap = {
  id: string
  source: string
  startCursor?: number
  endCursor?: number
  startTime?: string
  endTime?: string
  reason: string
  status:
    | "suspected"
    | "confirmed"
    | "backfill_queued"
    | "backfilling"
    | "verification_required"
    | "resolved"
    | "ignored"
  collections: string[]
  detectedAt: string
  updatedAt: string
  backfillJobId?: string
  discoveredCount: number
  processedCount: number
  failedCount: number
  reconciledCount: number
  version: number
  environment: EnvironmentName
}
export type GapCauseAssessment = {
  title: string
  confidence: "high" | "medium" | "low" | "insufficient"
  summary: string
  evidenceIds: string[]
  limitations: string[]
}
export type GapInvestigationEvidence = {
  id: string
  kind: "gap" | "stream" | "indexing" | "service" | "alert" | "trace"
  occurredAt: string
  service: string
  title: string
  detail: string
  attributes: Record<string, string>
  traceId?: string
}
export type GapInvestigation = {
  gap: Gap
  windowStart: string
  windowEnd: string
  assessment: GapCauseAssessment
  evidence: GapInvestigationEvidence[]
  recommendedActions: string[]
}
export type Backfill = {
  id: string
  gapId?: string
  sourceMode: "tap_verified_resync" | "jetstream_replay" | "pds_reconciliation"
  status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled"
  startCursor?: number
  endCursor?: number
  checkpointCursor?: number
  collections: string[]
  authorDids: string[]
  batchSize: number
  rateLimit: number
  maxConcurrency: number
  estimatedCount: number
  processedCount: number
  failedCount: number
  reconciledCount: number
  requestedByDid: string
  auditNote?: string
  failureReason?: string
  leaseOwner?: string
  leaseExpiresAt?: string
  createdAt: string
  updatedAt: string
  completedAt?: string
  version: number
  environment: EnvironmentName
  verificationStatus: "pending" | "required" | "verified" | "failed"
  verificationReason?: string
  scopeTruncated: boolean
  validationWatermark?: string
  authorResults: Array<{
    did: string
    collection: string
    discoveredCount: number
    processedCount: number
    failedCount: number
    capped: boolean
    truncated: boolean
    status: "succeeded" | "partial" | "failed" | "cancelled" | "unsupported"
    error?: string
  }>
}
export type Alert = {
  id: string
  rule: string
  conditionKey: string
  severity: string
  status: "open" | "acknowledged" | "resolved"
  summary: string
  evidence: Record<string, string>
  runbookSlug: string
  openedAt: string
  updatedAt: string
  acknowledgedByDid?: string
  resolvedByDid?: string
  deliveryAttempts: number
  lastDeliveryError?: string
  version: number
  environment: EnvironmentName
  nextDeliveryAt?: string
  deliveryDeadLetteredAt?: string
}
export type Span = {
  id: string
  environment: EnvironmentName
  traceId: string
  parentSpanId?: string
  service: string
  name: string
  startedAt: string
  durationMs: number
  status: string
  attributes: Record<string, string>
  expiresAt: string
}
export type TraceListResponse = {
  traces: Span[]
  nextCursor?: string | null
  totalCount: number
  truncated: boolean
  evidence: EvidenceEnvelope
}
export type MetricListResponse = {
  rollups: MetricRollup[]
  evidence: EvidenceEnvelope
}
export type MetricRollup = {
  environment: EnvironmentName
  bucketStart: string
  metricName: string
  dimensions: Record<string, string>
  sampleCount: number
  valueSum: number
  valueMin?: number
  valueMax?: number
}
export type DatabaseTableRecordCount = { schema: string; table: string; estimatedRecords: number }
export type DatabaseObservabilitySnapshot = {
  databaseSizeBytes: number
  activeConnections: number
  maxConnections: number
  transactionsTotal: number
  estimatedRecords: number
  cacheHitRatio?: number
  statsResetAt?: string
  topTables: DatabaseTableRecordCount[]
  connectedBackends: number
  activeQueries: number
  transactionRatePerSecond?: number
  observedAt: string
  evidenceAgeSeconds: number
}
export type Overview = {
  services: ServiceState[]
  ingestion?: StreamState
  ingestionSources: StreamState[]
  jetstreamEndpoints: JetstreamEndpoint[]
  commands: OperationsCommand[]
  gaps: Gap[]
  backfills: Backfill[]
  alerts: Alert[]
  recentTraces: Span[]
  metricRollups: MetricRollup[]
  database?: DatabaseObservabilitySnapshot
  refreshedAt: string
  evidence: OverviewEvidence
  capabilities: OperationsCapabilities
  counts: OperationsCounts
}
export type BackfillDryRun = {
  gapId?: string
  sourceMode: "tap_verified_resync" | "jetstream_replay" | "pds_reconciliation"
  startCursor?: number
  endCursor?: number
  collections: string[]
  authorDids: string[]
  batchSize: number
  rateLimit: number
  maxConcurrency: number
}
export type DryRunResult = {
  estimatedCount: number
  estimatedDurationSeconds: number
  snapshotEndCursor?: number
  conflicts: string[]
  unresolvedDeletesWarning: boolean
  requestFingerprint: string
  validUntil: string
  methodology: string
  confidence: string
  estimateKind: "observed" | "modeled"
  uncertainty?: { lowerBound: number; upperBound: number } | null
}

export type PageInfo = { nextCursor?: string; totalCount?: number }
export type GapListResponse = {
  gaps: Gap[]
  nextCursor?: string | null
  totalCount: number
  evidence: EvidenceEnvelope
}
export type BackfillListResponse = {
  backfills: Backfill[]
  nextCursor?: string | null
  totalCount: number
  evidence: EvidenceEnvelope
}
export type AlertListResponse = {
  alerts: Alert[]
  nextCursor?: string | null
  totalCount: number
  evidence: EvidenceEnvelope
}
export type CommandListResponse = {
  commands: OperationsCommand[]
  nextCursor?: string | null
  totalCount: number
  evidence: EvidenceEnvelope
}
export type EndpointListResponse = {
  endpoints: JetstreamEndpoint[]
  nextCursor?: string | null
  totalCount: number
  evidence: EvidenceEnvelope
}
export type ServiceListResponse = {
  services: ServiceState[]
  evidence: EvidenceEnvelope
}
export type IngestionResponse = {
  state?: StreamState
  sources: StreamState[]
  evidence: EvidenceEnvelope
}
export type AppViewOperationsResponse = {
  services: ServiceState[]
  evidence: EvidenceEnvelope
}
