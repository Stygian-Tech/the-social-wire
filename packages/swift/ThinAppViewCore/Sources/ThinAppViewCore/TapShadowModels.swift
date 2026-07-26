import Foundation

public struct IndexedContentIdentity: Sendable, Equatable {
  public let uri: String
  public let cid: String
  public let authorDid: String
  public let collection: String

  public init(uri: String, cid: String, authorDid: String, collection: String) {
    self.uri = uri
    self.cid = cid
    self.authorDid = authorDid
    self.collection = collection
  }
}

public enum TapContentMutation: Sendable {
  case upsert(IndexedContentItem)
  case delete(uri: String, authorDid: String, collection: String)

  public var uri: String {
    switch self {
    case .upsert(let item): item.uri
    case .delete(let uri, _, _): uri
    }
  }

  public var authorDid: String {
    switch self {
    case .upsert(let item): item.authorDid
    case .delete(_, let authorDid, _): authorDid
    }
  }

  public var collection: String {
    switch self {
    case .upsert(let item): item.collection
    case .delete(_, _, let collection): collection
    }
  }
}

public struct AppViewProjectionRepair: Sendable, Equatable {
  public let id: String
  public let environment: String
  public let eventId: Int64
  public let uri: String
  public let authorDid: String
  public let publicationSite: String?
  public let action: String
  public let attempts: Int
  public let leaseOwner: String
  public let leaseUntil: Date
}

/// Current durable projection work for one deployment environment.
///
/// Completed repairs are deleted from the outbox, so every counted row is unresolved. Failed
/// repairs remain actionable operator evidence rather than disappearing from completeness.
public struct AppViewProjectionRepairBacklogSnapshot: Sendable, Equatable {
  public let environment: String
  public let queuedCount: Int
  public let runningCount: Int
  public let failedCount: Int
  public let oldestActionableAt: Date?
  public let oldestActionableAgeSeconds: TimeInterval?
  public let observedAt: Date

  public init(
    environment: String,
    queuedCount: Int,
    runningCount: Int,
    failedCount: Int,
    oldestActionableAt: Date?,
    oldestActionableAgeSeconds: TimeInterval?,
    observedAt: Date
  ) {
    self.environment = environment
    self.queuedCount = queuedCount
    self.runningCount = runningCount
    self.failedCount = failedCount
    self.oldestActionableAt = oldestActionableAt
    self.oldestActionableAgeSeconds = oldestActionableAgeSeconds
    self.observedAt = observedAt
  }

}

public enum AppViewProjectionRepairError: Error {
  case staleLease
  case invalidBacklogEvidence
}

public struct TapDesiredRepositoryScope: Sendable, Equatable {
  public let repoDids: [String]
  public let truncated: Bool

  public init(repoDids: [String], truncated: Bool) {
    self.repoDids = repoDids
    self.truncated = truncated
  }
}

public enum TapAccountStatus: String, Codable, Sendable, Equatable {
  case active
  case takenDown = "takendown"
  case suspended
  case deactivated
  case deleted

  public var isActive: Bool { self == .active }
}

public enum TapParityStatus: String, Codable, Sendable, Equatable {
  case pending
  case matched
  case mismatch
  case lifecycleObserved = "lifecycle_observed"
  case authoritative
}

public enum TapParityDiscrepancyStatus: String, Codable, Sendable, Equatable {
  case open
  case resolved
}

public struct TapParityEventEvidence: Sendable, Equatable {
  public let uri: String
  public let collection: String
  public let mismatchKind: String?
  public let expectedCid: String?
  public let observedCid: String?

  public init(
    uri: String,
    collection: String,
    mismatchKind: String?,
    expectedCid: String?,
    observedCid: String?
  ) {
    self.uri = uri
    self.collection = collection
    self.mismatchKind = mismatchKind
    self.expectedCid = expectedCid
    self.observedCid = observedCid
  }
}

public struct TapParityDiscrepancy: Sendable, Equatable {
  public let environment: String
  public let eventId: Int64
  public let repoDid: String
  public let uri: String
  public let collection: String
  public let mismatchKind: String
  public let expectedCid: String?
  public let observedCid: String?
  public let status: TapParityDiscrepancyStatus
  public let openedAt: Date
  public let resolvedAt: Date?
  public let resolutionEventId: Int64?
}

/// Durable per-repository evidence produced by the Tap shadow/authoritative consumer.
public struct TapRepositorySyncState: Sendable, Equatable {
  public let environment: String
  public let repoDid: String
  public let repoRev: String?
  public let accountStatus: TapAccountStatus
  public let pdsBase: String?
  public let lastEventId: Int64?
  public let lastEventLive: Bool
  public let parityStatus: TapParityStatus
  public let matchedEventCount: Int64
  public let mismatchedEventCount: Int64
  public let lastMismatch: String?
  public let lastIndexedAt: Date?
  public let lastValidatedAt: Date?
  public let updatedAt: Date

  public init(
    environment: String,
    repoDid: String,
    repoRev: String?,
    accountStatus: TapAccountStatus,
    pdsBase: String?,
    lastEventId: Int64?,
    lastEventLive: Bool,
    parityStatus: TapParityStatus,
    matchedEventCount: Int64,
    mismatchedEventCount: Int64,
    lastMismatch: String?,
    lastIndexedAt: Date?,
    lastValidatedAt: Date?,
    updatedAt: Date
  ) {
    self.environment = environment
    self.repoDid = repoDid
    self.repoRev = repoRev
    self.accountStatus = accountStatus
    self.pdsBase = pdsBase
    self.lastEventId = lastEventId
    self.lastEventLive = lastEventLive
    self.parityStatus = parityStatus
    self.matchedEventCount = max(0, matchedEventCount)
    self.mismatchedEventCount = max(0, mismatchedEventCount)
    self.lastMismatch = lastMismatch
    self.lastIndexedAt = lastIndexedAt
    self.lastValidatedAt = lastValidatedAt
    self.updatedAt = updatedAt
  }
}
