import Foundation

public enum AppViewIngestionEventKind: String, Sendable, Codable, Equatable {
  case commit
  case identity
  case account
  case sync
}

public struct AppViewIngestionInboxItem: Sendable, Equatable {
  public let environment: String
  public let sourceGeneration: String
  public let sequence: Int64
  public let sourceHost: String
  public let eventKind: AppViewIngestionEventKind
  public let repoDid: String
  public let collection: String?
  public let operation: String?
  public let repoRev: String?
  public let recordKey: String?
  public let recordCID: String?
  public let payload: Data
  public let eventTime: Date
  public let attemptCount: Int
  public let leaseToken: String
  public let leaseExpiresAt: Date

  public init(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    sourceHost: String,
    eventKind: AppViewIngestionEventKind,
    repoDid: String,
    collection: String?,
    operation: String?,
    repoRev: String?,
    recordKey: String?,
    recordCID: String?,
    payload: Data,
    eventTime: Date,
    attemptCount: Int,
    leaseToken: String,
    leaseExpiresAt: Date
  ) {
    self.environment = environment
    self.sourceGeneration = sourceGeneration
    self.sequence = sequence
    self.sourceHost = sourceHost
    self.eventKind = eventKind
    self.repoDid = repoDid
    self.collection = collection
    self.operation = operation
    self.repoRev = repoRev
    self.recordKey = recordKey
    self.recordCID = recordCID
    self.payload = payload
    self.eventTime = eventTime
    self.attemptCount = attemptCount
    self.leaseToken = leaseToken
    self.leaseExpiresAt = leaseExpiresAt
  }
}

public enum AppViewIngestionInboxStoreError: Error, Sendable, Equatable {
  case staleLease
  case invalidRow
}

public struct AppViewIngestionReconciliationRequest: Sendable, Equatable {
  public let environment: String
  public let id: String
  public let sourceGeneration: String
  public let repoDid: String
  public let reason: String
  public let triggerSequence: Int64
  public let attemptCount: Int
  public let leaseToken: String
  public let leaseExpiresAt: Date
}
