import Foundation

public enum IngestionCursorKind: String, Codable, Sendable {
  case jetstreamV1TimeUS = "jetstream_v1_time_us"
  case jetstreamV2Sequence = "jetstream_v2_seq"
  case unknown
}

public enum JetstreamReplayState: String, Codable, Sendable {
  case idle
  case replaying
  case live
  case pausedBudget = "paused_budget"
  case failed
}

public struct JetstreamDurabilityCheckpoint: Codable, Sendable, Equatable {
  public let environment: String
  public let sourceGeneration: String
  public let sourceHost: String
  public let streamNSID: String
  public let filterFingerprint: String
  public let cursorKind: IngestionCursorKind
  public let lastStagedSequence: Int64?
  public let lastStagedEventAt: Date?
  public let lastStagedAt: Date?
  public let lastAppliedSequence: Int64?
  public let lastAppliedEventAt: Date?
  public let lastAppliedAt: Date?
  public let lastReconciledRepositoryRevision: String?
  public let lastReconciledAt: Date?
  public let replayState: JetstreamReplayState
  public let replayAfterSequence: Int64?
  public let replaySealedSequence: Int64?
  public let replayBytesDownloaded: Int64
  public let replayRetryCount: Int
  public let replayRangeResumeCount: Int
  public let replayLastProgressAt: Date?
  public let updatedAt: Date
}

public struct IngestionInboxMetrics: Codable, Sendable, Equatable {
  public let pending: Int
  public let leased: Int
  public let retrying: Int
  public let applied: Int
  public let deadLetters: Int
  public let total: Int
  public let oldestPendingAt: Date?
  public let oldestPendingAgeSeconds: Double?

  public init(
    pending: Int = 0,
    leased: Int = 0,
    retrying: Int = 0,
    applied: Int = 0,
    deadLetters: Int = 0,
    total: Int = 0,
    oldestPendingAt: Date? = nil,
    oldestPendingAgeSeconds: Double? = nil
  ) {
    self.pending = max(0, pending)
    self.leased = max(0, leased)
    self.retrying = max(0, retrying)
    self.applied = max(0, applied)
    self.deadLetters = max(0, deadLetters)
    self.total = max(0, total)
    self.oldestPendingAt = oldestPendingAt
    self.oldestPendingAgeSeconds = oldestPendingAgeSeconds.map { max(0, $0) }
  }
}

public struct IngestionIncidentMetrics: Codable, Sendable, Equatable {
  public let open: Int
  public let recovering: Int
  public let verificationRequired: Int
  public let resolved: Int
  public let ignored: Int
  public let latestDetectedAt: Date?

  public init(
    open: Int = 0,
    recovering: Int = 0,
    verificationRequired: Int = 0,
    resolved: Int = 0,
    ignored: Int = 0,
    latestDetectedAt: Date? = nil
  ) {
    self.open = max(0, open)
    self.recovering = max(0, recovering)
    self.verificationRequired = max(0, verificationRequired)
    self.resolved = max(0, resolved)
    self.ignored = max(0, ignored)
    self.latestDetectedAt = latestDetectedAt
  }
}

public struct IngestionDurabilitySnapshot: Codable, Sendable, Equatable {
  public let environment: String
  public let checkpoints: [JetstreamDurabilityCheckpoint]
  public let inbox: IngestionInboxMetrics
  public let incidents: IngestionIncidentMetrics
  public let replayBytesRolling24Hours: Int64
  public let generatedAt: Date

  public init(
    environment: String,
    checkpoints: [JetstreamDurabilityCheckpoint] = [],
    inbox: IngestionInboxMetrics = IngestionInboxMetrics(),
    incidents: IngestionIncidentMetrics = IngestionIncidentMetrics(),
    replayBytesRolling24Hours: Int64 = 0,
    generatedAt: Date = Date()
  ) {
    self.environment = environment
    self.checkpoints = checkpoints
    self.inbox = inbox
    self.incidents = incidents
    self.replayBytesRolling24Hours = max(0, replayBytesRolling24Hours)
    self.generatedAt = generatedAt
  }
}
