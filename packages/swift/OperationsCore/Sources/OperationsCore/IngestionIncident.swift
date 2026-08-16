import Foundation

public enum IngestionIncidentStatus: String, Codable, Sendable, CaseIterable {
  case open
  case recovering
  case verificationRequired = "verification_required"
  case resolved
  case ignored
}

public struct IngestionIncident: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let environment: String
  public let sourceGeneration: String?
  public let sourceHost: String?
  public let source: String
  public let cursorKind: IngestionCursorKind
  public let startCursor: Int64?
  public let endCursor: Int64?
  public let category: String
  public let status: IngestionIncidentStatus
  public let occurrenceCount: Int64
  public let firstDetectedAt: Date
  public let lastDetectedAt: Date
  public let lastError: String?
  public let replayState: JetstreamReplayState?
  public let replayBytesDownloaded: Int64
  public let replayRetryCount: Int
  public let replayRangeResumeCount: Int
  public let replaySealedSequence: Int64?
  public let recoveredThroughCursor: Int64?
  public let verificationEvidence: [String: OperationsJSONScalar]
  public let resolvedAt: Date?
  public let updatedAt: Date
  public let version: Int
}

public struct IngestionIncidentCandidate: Sendable, Equatable {
  public let sourceGeneration: String?
  public let sourceHost: String?
  public let source: String
  public let cursorKind: IngestionCursorKind
  public let startCursor: Int64?
  public let endCursor: Int64?
  public let category: String
  public let error: String?
  public let detectedAt: Date

  public init(
    sourceGeneration: String? = nil,
    sourceHost: String? = nil,
    source: String,
    cursorKind: IngestionCursorKind,
    startCursor: Int64? = nil,
    endCursor: Int64? = nil,
    category: String,
    error: String? = nil,
    detectedAt: Date = Date()
  ) {
    self.sourceGeneration = sourceGeneration
    self.sourceHost = sourceHost
    self.source = source
    self.cursorKind = cursorKind
    self.startCursor = startCursor
    self.endCursor = endCursor
    self.category = category
    self.error = error
    self.detectedAt = detectedAt
  }
}
