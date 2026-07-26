import Foundation

public enum OperationsHealthState: String, Codable, Sendable {
  case healthy
  case degraded
  case unhealthy
  case unknown
}

public enum IngestionConnectionState: String, Codable, Sendable {
  case connected
  case disconnected
  case reconnecting
  case unknown
}

public enum IngestionGapStatus: String, Codable, Sendable, CaseIterable {
  case suspected
  case confirmed
  case backfillQueued = "backfill_queued"
  case backfilling
  case verificationRequired = "verification_required"
  case resolved
  case ignored
}

public enum BackfillSourceMode: String, Codable, Sendable {
  case tapVerifiedResync = "tap_verified_resync"
  case jetstreamReplay = "jetstream_replay"
  case pdsReconciliation = "pds_reconciliation"
}

public enum BackfillVerificationStatus: String, Codable, Sendable {
  case pending
  case required
  case verified
  case failed
}

public enum BackfillAuthorResultStatus: String, Codable, Sendable {
  case succeeded
  case partial
  case failed
  case cancelled
  case unsupported
}

public struct BackfillAuthorResult: Codable, Sendable, Equatable {
  public let did: String
  public let collection: String
  public let discoveredCount: Int
  public let processedCount: Int
  public let failedCount: Int
  public let capped: Bool
  public let truncated: Bool
  public let status: BackfillAuthorResultStatus
  public let error: String?

  public init(
    did: String,
    collection: String,
    discoveredCount: Int,
    processedCount: Int,
    failedCount: Int,
    capped: Bool,
    truncated: Bool,
    status: BackfillAuthorResultStatus,
    error: String? = nil
  ) {
    self.did = did
    self.collection = collection
    self.discoveredCount = discoveredCount
    self.processedCount = processedCount
    self.failedCount = failedCount
    self.capped = capped
    self.truncated = truncated
    self.status = status
    self.error = error
  }
}

@propertyWrapper
public struct DefaultEmptyArray<Element: Codable & Sendable>: Codable, Sendable {
  public var wrappedValue: [Element]

  public init(wrappedValue: [Element] = []) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    wrappedValue = try container.decode([Element].self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wrappedValue)
  }
}

extension KeyedDecodingContainer {
  public func decode<Element>(
    _ type: DefaultEmptyArray<Element>.Type,
    forKey key: Key
  ) throws -> DefaultEmptyArray<Element> where Element: Codable & Sendable {
    try decodeIfPresent(type, forKey: key) ?? DefaultEmptyArray()
  }
}

public enum BackfillJobStatus: String, Codable, Sendable, CaseIterable {
  case queued
  case running
  case paused
  case completed
  case failed
  case cancelled
}

public enum OperationsAlertStatus: String, Codable, Sendable {
  case open
  case acknowledged
  case resolved
}

enum OperationsAlertDeliveryRetryPolicy {
  static let maximumAttempts = 8

  static func delaySeconds(alertId: String, attempt: Int) -> TimeInterval {
    let boundedAttempt = max(1, min(attempt, maximumAttempts - 1))
    let base = min(3_200, 15 * (1 << boundedAttempt))
    let maximumJitter = max(1, base / 4)
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in "\(alertId):\(boundedAttempt)".utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let jitter = Int(hash % UInt64(maximumJitter + 1))
    return TimeInterval(min(3_600, base + jitter))
  }
}

public enum JetstreamEndpointRole: String, Codable, Sendable {
  case active
  case standby
}

public struct JetstreamEndpointState: Codable, Sendable, Identifiable {
  public let id: String
  public let environment: String
  public let displayName: String
  public let host: String
  public let role: JetstreamEndpointRole
  public let connectionState: IngestionConnectionState
  public let lastConnectedAt: Date?
  public let lastDisconnectedAt: Date?
  public let lastError: String?
  public let connectionAttempts: Int
  public let failoverCount: Int
  public let updatedAt: Date
  public let version: Int

  public init(
    id: String,
    environment: String,
    displayName: String,
    host: String,
    role: JetstreamEndpointRole,
    connectionState: IngestionConnectionState,
    lastConnectedAt: Date? = nil,
    lastDisconnectedAt: Date? = nil,
    lastError: String? = nil,
    connectionAttempts: Int = 0,
    failoverCount: Int = 0,
    updatedAt: Date,
    version: Int = 0
  ) {
    self.id = id
    self.environment = environment
    self.displayName = displayName
    self.host = host
    self.role = role
    self.connectionState = connectionState
    self.lastConnectedAt = lastConnectedAt
    self.lastDisconnectedAt = lastDisconnectedAt
    self.lastError = lastError
    self.connectionAttempts = connectionAttempts
    self.failoverCount = failoverCount
    self.updatedAt = updatedAt
    self.version = version
  }
}

public enum OperationsCommandAction: String, Codable, Sendable {
  case reconnectJetstream = "reconnect_jetstream"
}

public enum OperationsCommandStatus: String, Codable, Sendable {
  case queued
  case running
  case completed
  case failed
}

public struct OperationsWorkerCommand: Codable, Sendable, Identifiable {
  public let id: String
  public let environment: String
  public let action: OperationsCommandAction
  public let status: OperationsCommandStatus
  public let requestedByDid: String
  public let auditNote: String?
  public let claimedBy: String?
  public let leaseExpiresAt: Date?
  public let failureReason: String?
  public let createdAt: Date
  public let updatedAt: Date
  public let completedAt: Date?
  public let version: Int

  public init(
    id: String,
    environment: String,
    action: OperationsCommandAction,
    status: OperationsCommandStatus,
    requestedByDid: String,
    auditNote: String?,
    claimedBy: String? = nil,
    leaseExpiresAt: Date? = nil,
    failureReason: String? = nil,
    createdAt: Date,
    updatedAt: Date,
    completedAt: Date? = nil,
    version: Int = 0
  ) {
    self.id = id
    self.environment = environment
    self.action = action
    self.status = status
    self.requestedByDid = requestedByDid
    self.auditNote = auditNote
    self.claimedBy = claimedBy
    self.leaseExpiresAt = leaseExpiresAt
    self.failureReason = failureReason
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.completedAt = completedAt
    self.version = version
  }
}

public struct OperationsServiceState: Codable, Sendable {
  public let service: String
  public let environment: String
  public let instanceId: String
  public let liveness: OperationsHealthState
  public let readiness: OperationsHealthState
  public let freshness: OperationsHealthState
  public let completeness: OperationsHealthState
  public let dependencyState: [String: String]
  public let version: String?
  public let startedAt: Date
  public let heartbeatAt: Date

  public init(
    service: String,
    environment: String,
    instanceId: String,
    liveness: OperationsHealthState,
    readiness: OperationsHealthState,
    freshness: OperationsHealthState,
    completeness: OperationsHealthState,
    dependencyState: [String: String] = [:],
    version: String? = nil,
    startedAt: Date,
    heartbeatAt: Date
  ) {
    self.service = service
    self.environment = environment
    self.instanceId = instanceId
    self.liveness = liveness
    self.readiness = readiness
    self.freshness = freshness
    self.completeness = completeness
    self.dependencyState = dependencyState
    self.version = version
    self.startedAt = startedAt
    self.heartbeatAt = heartbeatAt
  }
}

public struct IngestionStreamState: Codable, Sendable {
  public let environment: String
  public let source: String
  public let connectionState: IngestionConnectionState
  public let connectedAt: Date?
  public let lastDisconnectAt: Date?
  public let lastDisconnectReason: String?
  public let lastReceivedCursor: Int64?
  public let lastReceivedEventAt: Date?
  public let lastReceivedAt: Date?
  public let lastCommittedCursor: Int64?
  public let lastCommittedEventAt: Date?
  public let lastCommittedAt: Date?
  public let queueDepth: Int
  public let queueCapacity: Int?
  public let queueOverflowTotal: Int64?
  public let queueEvidence: OperationsEvidenceMetadata?
  public let transportHeartbeatAt: Date?
  public let lastIndexedMutationAt: Date?
  public let projectionWatermark: String?
  public let validationWatermark: String?
  public let heartbeatAt: Date
  public let version: Int

  public init(
    environment: String,
    source: String,
    connectionState: IngestionConnectionState,
    connectedAt: Date? = nil,
    lastDisconnectAt: Date? = nil,
    lastDisconnectReason: String? = nil,
    lastReceivedCursor: Int64? = nil,
    lastReceivedEventAt: Date? = nil,
    lastReceivedAt: Date? = nil,
    lastCommittedCursor: Int64? = nil,
    lastCommittedEventAt: Date? = nil,
    lastCommittedAt: Date? = nil,
    queueDepth: Int = 0,
    queueCapacity: Int? = nil,
    queueOverflowTotal: Int64? = nil,
    queueEvidence: OperationsEvidenceMetadata? = nil,
    transportHeartbeatAt: Date? = nil,
    lastIndexedMutationAt: Date? = nil,
    projectionWatermark: String? = nil,
    validationWatermark: String? = nil,
    heartbeatAt: Date,
    version: Int = 0
  ) {
    self.environment = environment
    self.source = source
    self.connectionState = connectionState
    self.connectedAt = connectedAt
    self.lastDisconnectAt = lastDisconnectAt
    self.lastDisconnectReason = lastDisconnectReason
    self.lastReceivedCursor = lastReceivedCursor
    self.lastReceivedEventAt = lastReceivedEventAt
    self.lastReceivedAt = lastReceivedAt
    self.lastCommittedCursor = lastCommittedCursor
    self.lastCommittedEventAt = lastCommittedEventAt
    self.lastCommittedAt = lastCommittedAt
    self.queueDepth = queueDepth
    self.queueCapacity = queueCapacity
    self.queueOverflowTotal = queueOverflowTotal
    self.queueEvidence = queueEvidence
    self.transportHeartbeatAt = transportHeartbeatAt
    self.lastIndexedMutationAt = lastIndexedMutationAt
    self.projectionWatermark = projectionWatermark
    self.validationWatermark = validationWatermark
    self.heartbeatAt = heartbeatAt
    self.version = version
  }
}

public struct IngestionGap: Codable, Sendable, Identifiable {
  public let id: String
  public let environment: String
  public let source: String
  public let startCursor: Int64?
  public let endCursor: Int64?
  public let startTime: Date?
  public let endTime: Date?
  public let reason: String
  public let status: IngestionGapStatus
  public let collections: [String]
  public let detectedAt: Date
  public let updatedAt: Date
  public let backfillJobId: String?
  public let discoveredCount: Int
  public let processedCount: Int
  public let failedCount: Int
  public let reconciledCount: Int
  public let version: Int
}

public struct BackfillJob: Codable, Sendable, Identifiable {
  public let id: String
  public let environment: String
  public let gapId: String?
  public let sourceMode: BackfillSourceMode
  public let status: BackfillJobStatus
  public let startCursor: Int64?
  public let endCursor: Int64?
  public let checkpointCursor: Int64?
  public let collections: [String]
  public let authorDids: [String]
  @DefaultEmptyArray public var authorResults: [BackfillAuthorResult]
  public let batchSize: Int
  public let rateLimit: Int
  public let maxConcurrency: Int
  public let estimatedCount: Int
  public let processedCount: Int
  public let failedCount: Int
  public let reconciledCount: Int
  public let requestedByDid: String
  public let auditNote: String?
  public let failureReason: String?
  public let leaseOwner: String?
  public let leaseExpiresAt: Date?
  public let createdAt: Date
  public let updatedAt: Date
  public let completedAt: Date?
  public let version: Int
  public let verificationStatus: BackfillVerificationStatus
  public let verificationReason: String?
  public let scopeTruncated: Bool
  public let validationWatermark: String?
}

public struct BackfillDryRunRequest: Codable, Sendable {
  public let gapId: String?
  public let sourceMode: BackfillSourceMode
  public let startCursor: Int64?
  public let endCursor: Int64?
  public let collections: [String]
  public let authorDids: [String]
  public let batchSize: Int
  public let rateLimit: Int
  public let maxConcurrency: Int

  public init(
    gapId: String? = nil,
    sourceMode: BackfillSourceMode,
    startCursor: Int64? = nil,
    endCursor: Int64? = nil,
    collections: [String],
    authorDids: [String] = [],
    batchSize: Int,
    rateLimit: Int,
    maxConcurrency: Int
  ) {
    self.gapId = gapId
    self.sourceMode = sourceMode
    self.startCursor = startCursor
    self.endCursor = endCursor
    self.collections = collections
    self.authorDids = authorDids
    self.batchSize = batchSize
    self.rateLimit = rateLimit
    self.maxConcurrency = maxConcurrency
  }
}

public struct BackfillDryRunResponse: Codable, Sendable {
  public let estimatedCount: Int
  public let estimatedDurationSeconds: Int
  public let snapshotEndCursor: Int64?
  public let conflicts: [String]
  public let unresolvedDeletesWarning: Bool
  public let requestFingerprint: String
  public let validUntil: Date
  public let methodology: String
  public let confidence: String
  public let estimateKind: BackfillEstimateKind
  public let uncertainty: BackfillEstimateUncertainty?

  public init(
    estimatedCount: Int,
    estimatedDurationSeconds: Int,
    snapshotEndCursor: Int64?,
    conflicts: [String],
    unresolvedDeletesWarning: Bool,
    requestFingerprint: String,
    validUntil: Date,
    methodology: String,
    confidence: String,
    estimateKind: BackfillEstimateKind,
    uncertainty: BackfillEstimateUncertainty?
  ) {
    self.estimatedCount = estimatedCount
    self.estimatedDurationSeconds = estimatedDurationSeconds
    self.snapshotEndCursor = snapshotEndCursor
    self.conflicts = conflicts
    self.unresolvedDeletesWarning = unresolvedDeletesWarning
    self.requestFingerprint = requestFingerprint
    self.validUntil = validUntil
    self.methodology = methodology
    self.confidence = confidence
    self.estimateKind = estimateKind
    self.uncertainty = uncertainty
  }

  public func replacingRequestFingerprint(_ fingerprint: String) -> BackfillDryRunResponse {
    BackfillDryRunResponse(
      estimatedCount: estimatedCount,
      estimatedDurationSeconds: estimatedDurationSeconds,
      snapshotEndCursor: snapshotEndCursor,
      conflicts: conflicts,
      unresolvedDeletesWarning: unresolvedDeletesWarning,
      requestFingerprint: fingerprint,
      validUntil: validUntil,
      methodology: methodology,
      confidence: confidence,
      estimateKind: estimateKind,
      uncertainty: uncertainty)
  }
}

public enum BackfillEstimateKind: String, Codable, Sendable {
  case observed
  case modeled
}

public struct BackfillEstimateUncertainty: Codable, Sendable {
  public let lowerBound: Int
  public let upperBound: Int

  public init(lowerBound: Int, upperBound: Int) {
    self.lowerBound = lowerBound
    self.upperBound = upperBound
  }
}

public struct CreateBackfillRequest: Codable, Sendable {
  public let dryRun: BackfillDryRunRequest
  public let expectedEstimate: Int
  public let auditNote: String?
  public let environmentConfirmation: String?
  public let idempotencyKey: String
  public let expectedGapVersion: Int?
  public let requestFingerprint: String

  public init(
    dryRun: BackfillDryRunRequest,
    expectedEstimate: Int,
    auditNote: String?,
    environmentConfirmation: String?,
    idempotencyKey: String,
    expectedGapVersion: Int? = nil,
    requestFingerprint: String
  ) {
    self.dryRun = dryRun
    self.expectedEstimate = expectedEstimate
    self.auditNote = auditNote
    self.environmentConfirmation = environmentConfirmation
    self.idempotencyKey = idempotencyKey
    self.expectedGapVersion = expectedGapVersion
    self.requestFingerprint = requestFingerprint
  }
}

public struct OperationsAlert: Codable, Sendable, Identifiable {
  public let id: String
  public let environment: String
  public let rule: String
  public let conditionKey: String
  public let severity: String
  public let status: OperationsAlertStatus
  public let summary: String
  public let evidence: [String: String]
  public let runbookSlug: String
  public let openedAt: Date
  public let updatedAt: Date
  public let acknowledgedByDid: String?
  public let resolvedByDid: String?
  public let deliveryAttempts: Int
  public let lastDeliveryError: String?
  public let nextDeliveryAt: Date?
  public let deliveryDeadLetteredAt: Date?
  public let version: Int
}

public struct TraceSpan: Codable, Sendable, Identifiable {
  public let id: String
  public let environment: String
  public let traceId: String
  public let parentSpanId: String?
  public let service: String
  public let name: String
  public let startedAt: Date
  public let durationMs: Double
  public let status: String
  public let attributes: [String: String]
  public let expiresAt: Date

  public init(
    id: String = UUID().uuidString.lowercased(),
    environment: String,
    traceId: String,
    parentSpanId: String? = nil,
    service: String,
    name: String,
    startedAt: Date,
    durationMs: Double,
    status: String,
    attributes: [String: String],
    expiresAt: Date
  ) {
    self.id = id
    self.environment = environment
    self.traceId = traceId
    self.parentSpanId = parentSpanId
    self.service = service
    self.name = name
    self.startedAt = startedAt
    self.durationMs = durationMs
    self.status = status
    self.attributes = attributes
    self.expiresAt = expiresAt
  }
}

public struct OperationsMetricSample: Sendable {
  public let name: String
  public let value: Double
  public let dimensions: [String: String]
  public let recordedAt: Date

  public init(name: String, value: Double, dimensions: [String: String], recordedAt: Date = Date())
  {
    self.name = name
    self.value = value
    self.dimensions = dimensions
    self.recordedAt = recordedAt
  }
}

public struct OperationsMetricRollup: Codable, Sendable {
  public let environment: String
  public let bucketStart: Date
  public let metricName: String
  public let dimensions: [String: String]
  public let sampleCount: Int
  public let valueSum: Double
  public let valueMin: Double?
  public let valueMax: Double?

  public init(
    environment: String,
    bucketStart: Date,
    metricName: String,
    dimensions: [String: String],
    sampleCount: Int,
    valueSum: Double,
    valueMin: Double?,
    valueMax: Double?
  ) {
    self.environment = environment
    self.bucketStart = bucketStart
    self.metricName = metricName
    self.dimensions = dimensions
    self.sampleCount = sampleCount
    self.valueSum = valueSum
    self.valueMin = valueMin
    self.valueMax = valueMax
  }
}

public struct OperationsEvent: Codable, Sendable {
  public let id: String
  public let service: String
  public let environment: String
  public let instanceId: String
  public let name: String
  public let occurredAt: Date
  public let requestId: String?
  public let traceId: String?
  public let attributes: [String: String]

  public init(
    id: String = UUID().uuidString.lowercased(),
    service: String,
    environment: String,
    instanceId: String,
    name: String,
    occurredAt: Date = Date(),
    requestId: String? = nil,
    traceId: String? = nil,
    attributes: [String: String] = [:]
  ) {
    self.id = id
    self.service = service
    self.environment = environment
    self.instanceId = instanceId
    self.name = name
    self.occurredAt = occurredAt
    self.requestId = requestId
    self.traceId = traceId
    self.attributes = attributes
  }
}

public struct OperationsChangeEvent: Codable, Sendable, Equatable, Identifiable {
  public var id: Int64 { cursor }
  public let environment: String
  public let cursor: Int64
  public let eventType: String
  public let entityType: String
  public let entityId: String?
  public let payload: [String: String]
  public let occurredAt: Date

  public init(
    environment: String,
    cursor: Int64,
    eventType: String,
    entityType: String,
    entityId: String? = nil,
    payload: [String: String] = [:],
    occurredAt: Date
  ) {
    self.environment = environment
    self.cursor = cursor
    self.eventType = eventType
    self.entityType = entityType
    self.entityId = entityId
    self.payload = payload
    self.occurredAt = occurredAt
  }
}

public struct OperationsChangeEventCursorBounds: Codable, Sendable, Equatable {
  public let earliestAvailable: Int64
  public let latest: Int64

  public init(earliestAvailable: Int64, latest: Int64) {
    self.earliestAvailable = earliestAvailable
    self.latest = latest
  }

  public func canResume(after cursor: Int64) -> Bool {
    (cursor == 0 || cursor >= earliestAvailable - 1) && cursor <= latest
  }
}

/// Durable context for an operator mutation attempt. Failed and rejected attempts are
/// intentionally first-class audit records rather than log-only diagnostics.
public struct OperationsMutationAudit: Sendable {
  public let operatorDid: String
  public let requestId: String
  public let action: String
  public let targetType: String
  public let targetId: String?
  public let idempotencyKey: String?
  public let expectedVersion: Int?
  public let note: String?
  public let before: [String: String]
  public let after: [String: String]
  public let outcome: String
  public let occurredAt: Date

  public init(
    operatorDid: String,
    requestId: String,
    action: String,
    targetType: String,
    targetId: String? = nil,
    idempotencyKey: String? = nil,
    expectedVersion: Int? = nil,
    note: String? = nil,
    before: [String: String] = [:],
    after: [String: String] = [:],
    outcome: String,
    occurredAt: Date = Date()
  ) {
    self.operatorDid = operatorDid
    self.requestId = requestId
    self.action = action
    self.targetType = targetType
    self.targetId = targetId
    self.idempotencyKey = idempotencyKey
    self.expectedVersion = expectedVersion
    self.note = note
    self.before = before
    self.after = after
    self.outcome = outcome
    self.occurredAt = occurredAt
  }
}

public struct DatabaseTableRecordCount: Codable, Sendable {
  public let schema: String
  public let table: String
  public let estimatedRecords: Int64

  public init(schema: String, table: String, estimatedRecords: Int64) {
    self.schema = schema
    self.table = table
    self.estimatedRecords = estimatedRecords
  }
}

public struct DatabaseObservabilitySnapshot: Codable, Sendable {
  public let databaseSizeBytes: Int64
  public let activeConnections: Int64
  public let maxConnections: Int64
  public let transactionsTotal: Int64
  public let estimatedRecords: Int64
  public let cacheHitRatio: Double?
  public let statsResetAt: Date?
  public let topTables: [DatabaseTableRecordCount]
  public let connectedBackends: Int64
  public let activeQueries: Int64
  public let transactionRatePerSecond: Double?
  public let observedAt: Date
  public let evidenceAgeSeconds: Double

  public init(
    databaseSizeBytes: Int64,
    activeConnections: Int64,
    maxConnections: Int64,
    transactionsTotal: Int64,
    estimatedRecords: Int64,
    cacheHitRatio: Double?,
    statsResetAt: Date?,
    topTables: [DatabaseTableRecordCount],
    connectedBackends: Int64? = nil,
    activeQueries: Int64 = 0,
    transactionRatePerSecond: Double? = nil,
    observedAt: Date = Date(),
    evidenceAgeSeconds: Double = 0
  ) {
    self.databaseSizeBytes = databaseSizeBytes
    self.activeConnections = activeConnections
    self.maxConnections = maxConnections
    self.transactionsTotal = transactionsTotal
    self.estimatedRecords = estimatedRecords
    self.cacheHitRatio = cacheHitRatio
    self.statsResetAt = statsResetAt
    self.topTables = topTables
    self.connectedBackends = connectedBackends ?? activeConnections
    self.activeQueries = activeQueries
    self.transactionRatePerSecond = transactionRatePerSecond
    self.observedAt = observedAt
    self.evidenceAgeSeconds = max(0, evidenceAgeSeconds)
  }
}

public enum OperationsEvidenceAccuracy: String, Codable, Sendable {
  case exact
  case sampled
  case estimated
  case unavailable
}

public struct OperationsEvidenceMetadata: Codable, Sendable {
  public let source: String
  public let accuracy: OperationsEvidenceAccuracy
  public let generatedAt: Date
  public let indexedThrough: Date?
  public let ageSeconds: Double
  public let validUntil: Date
  public let coverage: Double?
  public let lastSuccessfulAt: Date?
  public let degradedReason: String?

  public init(
    source: String,
    accuracy: OperationsEvidenceAccuracy,
    generatedAt: Date,
    indexedThrough: Date? = nil,
    ageSeconds: Double,
    validUntil: Date,
    coverage: Double? = nil,
    lastSuccessfulAt: Date? = nil,
    degradedReason: String? = nil
  ) {
    self.source = source
    self.accuracy = accuracy
    self.generatedAt = generatedAt
    self.indexedThrough = indexedThrough
    self.ageSeconds = max(0, ageSeconds)
    self.validUntil = validUntil
    self.coverage = coverage
    self.lastSuccessfulAt = lastSuccessfulAt
    self.degradedReason = degradedReason
  }
}

public struct OperationsCapability: Codable, Sendable {
  public let enabled: Bool
  public let disabledReason: String?

  public init(enabled: Bool, disabledReason: String? = nil) {
    self.enabled = enabled
    self.disabledReason = enabled ? nil : disabledReason
  }
}

public struct OperationsCapabilities: Codable, Sendable {
  public let environment: String
  public let telemetry: OperationsCapability
  public let recovery: OperationsCapability
  public let recoveryModes: OperationsRecoveryModeCapabilities
  public let alertDelivery: OperationsCapability
  public let eventStream: OperationsEventStreamCapability
  public let generatedAt: Date

  public init(
    environment: String,
    telemetry: OperationsCapability,
    recovery: OperationsCapability,
    recoveryModes: OperationsRecoveryModeCapabilities = .allDisabled(
      reason: "Recovery mode capabilities have not been reported."),
    alertDelivery: OperationsCapability,
    eventStream: OperationsEventStreamCapability = OperationsEventStreamCapability(
      enabled: false,
      disabledReason: "Resumable event streaming is not enabled.",
      path: "/v1/operations/events/stream"),
    generatedAt: Date = Date()
  ) {
    self.environment = environment
    self.telemetry = telemetry
    self.recovery = recovery
    self.recoveryModes = recoveryModes
    self.alertDelivery = alertDelivery
    self.eventStream = eventStream
    self.generatedAt = generatedAt
  }
}

public struct OperationsRecoveryModeCapabilities: Codable, Sendable {
  public let tapVerifiedResync: OperationsCapability
  public let jetstreamReplay: OperationsCapability
  public let pdsReconciliation: OperationsCapability

  public init(
    tapVerifiedResync: OperationsCapability,
    jetstreamReplay: OperationsCapability,
    pdsReconciliation: OperationsCapability
  ) {
    self.tapVerifiedResync = tapVerifiedResync
    self.jetstreamReplay = jetstreamReplay
    self.pdsReconciliation = pdsReconciliation
  }

  public static func allDisabled(reason: String) -> OperationsRecoveryModeCapabilities {
    OperationsRecoveryModeCapabilities(
      tapVerifiedResync: OperationsCapability(enabled: false, disabledReason: reason),
      jetstreamReplay: OperationsCapability(enabled: false, disabledReason: reason),
      pdsReconciliation: OperationsCapability(enabled: false, disabledReason: reason))
  }
}

public struct OperationsEventStreamCapability: Codable, Sendable {
  public let enabled: Bool
  public let disabledReason: String?
  public let path: String
  public let retryMilliseconds: Int
  public let fallbackPollMilliseconds: Int

  public init(
    enabled: Bool,
    disabledReason: String? = nil,
    path: String,
    retryMilliseconds: Int = 2_000,
    fallbackPollMilliseconds: Int = 5_000
  ) {
    self.enabled = enabled
    self.disabledReason = enabled ? nil : disabledReason
    self.path = path
    self.retryMilliseconds = retryMilliseconds
    self.fallbackPollMilliseconds = fallbackPollMilliseconds
  }
}

public struct OperationsLifecycleCounts: Codable, Sendable, Equatable {
  public let activeGaps: Int
  public let activeBackfills: Int
  public let attentionBackfills: Int
  public let completedBackfills: Int
  public let unresolvedAlerts: Int

  public init(
    activeGaps: Int = 0,
    activeBackfills: Int = 0,
    attentionBackfills: Int = 0,
    completedBackfills: Int = 0,
    unresolvedAlerts: Int = 0
  ) {
    self.activeGaps = activeGaps
    self.activeBackfills = activeBackfills
    self.attentionBackfills = attentionBackfills
    self.completedBackfills = completedBackfills
    self.unresolvedAlerts = unresolvedAlerts
  }
}

public enum GapListView: String, Codable, Sendable {
  case active
  case history
  case all
}

public enum BackfillListView: String, Codable, Sendable {
  case active
  case attention
  case history
  case all
}

public enum AlertListView: String, Codable, Sendable {
  case active
  case history
  case all
}

public struct OperationsPage<Element: Codable & Sendable>: Codable, Sendable {
  public let items: [Element]
  public let nextCursor: String?
  public let totalCount: Int

  public init(items: [Element], nextCursor: String?, totalCount: Int) {
    self.items = items
    self.nextCursor = nextCursor
    self.totalCount = totalCount
  }
}

public struct OperationsOverview: Codable, Sendable {
  public let services: [OperationsServiceState]
  public let ingestion: IngestionStreamState?
  public let ingestionSources: [IngestionStreamState]
  public let jetstreamEndpoints: [JetstreamEndpointState]
  public let commands: [OperationsWorkerCommand]
  public let gaps: [IngestionGap]
  public let backfills: [BackfillJob]
  public let alerts: [OperationsAlert]
  public let recentTraces: [TraceSpan]
  public let metricRollups: [OperationsMetricRollup]
  public let database: DatabaseObservabilitySnapshot?
  public let refreshedAt: Date
  public let evidence: [String: OperationsEvidenceMetadata]
  public let capabilities: OperationsCapabilities?
  public let counts: OperationsLifecycleCounts

  public init(
    services: [OperationsServiceState],
    ingestion: IngestionStreamState?,
    ingestionSources: [IngestionStreamState] = [],
    jetstreamEndpoints: [JetstreamEndpointState],
    commands: [OperationsWorkerCommand],
    gaps: [IngestionGap],
    backfills: [BackfillJob],
    alerts: [OperationsAlert],
    recentTraces: [TraceSpan],
    metricRollups: [OperationsMetricRollup],
    database: DatabaseObservabilitySnapshot?,
    refreshedAt: Date,
    evidence: [String: OperationsEvidenceMetadata] = [:],
    capabilities: OperationsCapabilities? = nil,
    counts: OperationsLifecycleCounts = OperationsLifecycleCounts()
  ) {
    self.services = services
    self.ingestion = ingestion
    self.ingestionSources = ingestionSources
    self.jetstreamEndpoints = jetstreamEndpoints
    self.commands = commands
    self.gaps = gaps
    self.backfills = backfills
    self.alerts = alerts
    self.recentTraces = recentTraces
    self.metricRollups = metricRollups
    self.database = database
    self.refreshedAt = refreshedAt
    self.evidence = evidence
    self.capabilities = capabilities
    self.counts = counts
  }
}
