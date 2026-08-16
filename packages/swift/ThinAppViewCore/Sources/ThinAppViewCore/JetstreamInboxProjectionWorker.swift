import Foundation
import Logging

public final class JetstreamInboxProjectionWorker: Sendable {
  private let store: any ThinAppViewStore
  private let indexers: [ThinAppViewIndexer]
  private let repositoryRestorer: (any TapRepositoryRestorer)?
  private let environment: String
  private let sourceGeneration: String
  private let workerId: String
  private let maxConcurrency: Int
  private let leaseSeconds: TimeInterval
  private let pollMilliseconds: Int
  private let appliedRetentionSeconds: TimeInterval
  private let deadLetterRetentionSeconds: TimeInterval
  private let projectionTimeoutSeconds: TimeInterval
  private let logger: Logger

  public init(
    store: any ThinAppViewStore,
    indexers: [ThinAppViewIndexer],
    repositoryRestorer: (any TapRepositoryRestorer)? = nil,
    environment: String,
    sourceGeneration: String,
    workerId: String,
    maxConcurrency: Int,
    leaseSeconds: TimeInterval,
    pollMilliseconds: Int,
    appliedRetentionSeconds: TimeInterval,
    deadLetterRetentionSeconds: TimeInterval,
    projectionTimeoutSeconds: TimeInterval = 120,
    logger: Logger
  ) {
    precondition(!indexers.isEmpty, "At least one ThinAppViewIndexer is required.")
    self.store = store
    self.indexers = indexers
    self.repositoryRestorer = repositoryRestorer
    self.environment = environment
    self.sourceGeneration = sourceGeneration
    self.workerId = workerId
    self.maxConcurrency = max(1, min(maxConcurrency, indexers.count))
    self.leaseSeconds = max(5, leaseSeconds)
    self.pollMilliseconds = max(25, pollMilliseconds)
    self.appliedRetentionSeconds = max(60, appliedRetentionSeconds)
    self.deadLetterRetentionSeconds = max(60, deadLetterRetentionSeconds)
    self.projectionTimeoutSeconds = max(0.01, projectionTimeoutSeconds)
    self.logger = logger
  }

  public func runForever() async {
    logger.info(
      "Starting durable Jetstream V2 inbox projection",
      metadata: [
        "source_generation": .string(sourceGeneration),
        "max_concurrency": .stringConvertible(maxConcurrency),
      ]
    )
    while !Task.isCancelled {
      do {
        let claimed = try await drainOnce()
        if claimed == 0 {
          try await Task.sleep(for: .milliseconds(pollMilliseconds))
        }
      } catch is CancellationError {
        return
      } catch {
        logger.error(
          "Jetstream V2 inbox claim failed",
          metadata: ["error_type": .string(Self.failureCategory(error))]
        )
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  @discardableResult
  public func drainOnce(at now: Date = Date()) async throws -> Int {
    let items = try await store.claimIngestionInbox(
      environment: environment,
      sourceGeneration: sourceGeneration,
      workerId: workerId,
      limit: maxConcurrency,
      leaseUntil: now.addingTimeInterval(leaseSeconds),
      at: now
    )
    if !items.isEmpty {
      await withTaskGroup(of: Void.self) { group in
        for item in items {
          let indexer = indexers[Self.lane(for: item.repoDid, count: indexers.count)]
          group.addTask {
            await self.process(item, with: indexer)
          }
        }
      }
    }
    let reconciliations = try await drainReconciliations(at: Date())
    try await store.advanceIngestionInboxAppliedWatermark(
      environment: environment,
      sourceGeneration: sourceGeneration,
      at: Date()
    )
    _ = try await store.resolveRecoveredIngestionIncidents(
      environment: environment,
      sourceGeneration: sourceGeneration,
      at: Date()
    )
    return items.count + reconciliations
  }

  private func drainReconciliations(at now: Date) async throws -> Int {
    guard repositoryRestorer != nil else { return 0 }
    let requests = try await store.claimIngestionReconciliationRequests(
      environment: environment,
      sourceGeneration: sourceGeneration,
      workerId: workerId,
      limit: maxConcurrency,
      leaseUntil: now.addingTimeInterval(leaseSeconds),
      at: now
    )
    await withTaskGroup(of: Void.self) { group in
      for request in requests {
        group.addTask { await self.processReconciliation(request) }
      }
    }
    return requests.count
  }

  private func process(
    _ item: AppViewIngestionInboxItem,
    with indexer: ThinAppViewIndexer
  ) async {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.apply(item, with: indexer) }
        group.addTask { try await self.renewLeaseUntilCancelled(for: item) }
        group.addTask { try await self.failAfterProjectionTimeout() }
        do {
          _ = try await group.next()
          group.cancelAll()
          while let _ = try await group.next() {}
        } catch {
          group.cancelAll()
          throw error
        }
      }
    } catch is CancellationError {
      return
    } catch {
      await handleFailure(error, item: item)
    }
  }

  private func apply(
    _ item: AppViewIngestionInboxItem,
    with indexer: ThinAppViewIndexer
  ) async throws {
    let event = try JetstreamV2ProjectionEventParser.parse(
      item.payload,
      expectedSequence: item.sequence,
      expectedKind: item.eventKind,
      expectedRepoDid: item.repoDid
    )
    try Self.validateNormalizedMetadata(item, event: event)
    switch event {
    case .commit(let commit):
      guard commit.operation == .delete || commit.recordJSON != nil else {
        throw JetstreamInboxProjectionError.commitRecordUnavailable
      }
      try await indexer.handleCommit(
        repoDid: commit.did,
        collection: commit.collection,
        rkey: commit.rkey,
        cid: commit.cid ?? "",
        recordJSON: commit.recordJSON ?? Data("{}".utf8),
        operation: commit.operation.rawValue,
        ingestionSource: "jetstream_v2",
        ingestionEnvironment: item.environment,
        repoRev: commit.repoRev,
        cursor: String(commit.sequence),
        eventTime: commit.eventTime
      )

    case .identity(let identity):
      // An identity event invalidates cached DID document/PDS resolution without deleting rows.
      try await indexer.handleIdentity(repoDid: identity.did, status: .active, isActive: true)

    case .account(let account):
      try await indexer.handleIdentity(
        repoDid: account.did,
        status: account.status,
        isActive: account.active
      )

    case .sync(let sync):
      guard let repositoryRestorer else {
        throw JetstreamInboxProjectionError.repositoryReconciliationUnavailable
      }
      let report = try await repositoryRestorer.restoreCurrentRepository(repoDid: sync.did)
      guard report.complete else {
        throw JetstreamInboxProjectionError.repositoryReconciliationIncomplete
      }
      try await store.markIngestionInboxReconciled(
        environment: item.environment,
        sourceGeneration: item.sourceGeneration,
        sequence: item.sequence,
        repoDid: item.repoDid,
        repoRev: sync.repoRev,
        workerId: workerId,
        leaseToken: item.leaseToken,
        expiresAt: Date().addingTimeInterval(appliedRetentionSeconds),
        at: Date()
      )
    }

    try await store.markIngestionInboxApplied(
      environment: item.environment,
      sourceGeneration: item.sourceGeneration,
      sequence: item.sequence,
      workerId: workerId,
      leaseToken: item.leaseToken,
      expiresAt: Date().addingTimeInterval(appliedRetentionSeconds),
      at: Date()
    )
  }

  private func renewLeaseUntilCancelled(for item: AppViewIngestionInboxItem) async throws {
    let interval = max(1, leaseSeconds / 3)
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(interval))
        try Task.checkCancellation()
      } catch is CancellationError {
        return
      }
      let now = Date()
      do {
        try await store.renewIngestionInboxLease(
          environment: item.environment,
          sourceGeneration: item.sourceGeneration,
          sequence: item.sequence,
          workerId: workerId,
          leaseToken: item.leaseToken,
          leaseUntil: now.addingTimeInterval(leaseSeconds),
          at: now
        )
      } catch {
        // Applying the event cancels this sibling. A renewal already in flight may then observe the
        // terminal row and return staleLease; cancellation makes that expected, not a projection
        // failure that should be retried.
        if Task.isCancelled { return }
        throw error
      }
    }
  }

  private func processReconciliation(_ request: AppViewIngestionReconciliationRequest) async {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.applyReconciliation(request) }
        group.addTask { try await self.renewReconciliationUntilCancelled(for: request) }
        group.addTask { try await self.failAfterProjectionTimeout() }
        do {
          _ = try await group.next()
          group.cancelAll()
          while let _ = try await group.next() {}
        } catch {
          group.cancelAll()
          throw error
        }
      }
    } catch is CancellationError {
      return
    } catch {
      do {
        let attempt = request.attemptCount + 1
        let delay = Self.retryDelaySeconds(
          attempt: attempt, jitterUnit: Double.random(in: 0...1))
        try await store.retryIngestionReconciliation(
          environment: request.environment,
          requestId: request.id,
          workerId: workerId,
          leaseToken: request.leaseToken,
          failureReason: String(describing: error),
          nextAttemptAt: Date().addingTimeInterval(delay),
          at: Date()
        )
      } catch {
        logger.error(
          "Failed to persist targeted repository reconciliation retry",
          metadata: ["request_id": .string(request.id)])
      }
    }
  }

  private func applyReconciliation(
    _ request: AppViewIngestionReconciliationRequest
  ) async throws {
    guard let repositoryRestorer else {
      throw JetstreamInboxProjectionError.repositoryReconciliationUnavailable
    }
    let report = try await repositoryRestorer.restoreCurrentRepository(repoDid: request.repoDid)
    guard report.complete else {
      throw JetstreamInboxProjectionError.repositoryReconciliationIncomplete
    }
    try await store.completeIngestionReconciliation(
      environment: request.environment,
      requestId: request.id,
      sourceGeneration: request.sourceGeneration,
      repoDid: request.repoDid,
      triggerSequence: request.triggerSequence,
      workerId: workerId,
      leaseToken: request.leaseToken,
      expiresAt: Date().addingTimeInterval(deadLetterRetentionSeconds),
      at: Date()
    )
  }

  private func failAfterProjectionTimeout() async throws {
    do {
      try await Task.sleep(for: .seconds(projectionTimeoutSeconds))
    } catch is CancellationError {
      return
    }
    throw JetstreamInboxProjectionError.projectionTimedOut
  }

  private func renewReconciliationUntilCancelled(
    for request: AppViewIngestionReconciliationRequest
  ) async throws {
    let interval = max(1, leaseSeconds / 3)
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(interval))
        try Task.checkCancellation()
      } catch is CancellationError {
        return
      }
      let now = Date()
      do {
        try await store.renewIngestionReconciliationLease(
          environment: request.environment,
          requestId: request.id,
          workerId: workerId,
          leaseToken: request.leaseToken,
          leaseUntil: now.addingTimeInterval(leaseSeconds),
          at: now
        )
      } catch {
        if Task.isCancelled { return }
        throw error
      }
    }
  }

  private func handleFailure(_ error: any Error, item: AppViewIngestionInboxItem) async {
    let attempt = item.attemptCount + 1
    let category = Self.failureCategory(error)
    let reason = String(describing: error)
    do {
      if attempt >= 10 {
        try await store.deadLetterIngestionInbox(
          environment: item.environment,
          sourceGeneration: item.sourceGeneration,
          sequence: item.sequence,
          repoDid: item.repoDid,
          workerId: workerId,
          leaseToken: item.leaseToken,
          failureCategory: category,
          failureReason: reason,
          expiresAt: Date().addingTimeInterval(deadLetterRetentionSeconds),
          at: Date()
        )
        logger.error(
          "Jetstream V2 inbox event dead-lettered for repository reconciliation",
          metadata: [
            "sequence": .stringConvertible(item.sequence),
            "event_kind": .string(item.eventKind.rawValue),
            "attempt": .stringConvertible(attempt),
            "error_type": .string(category),
          ]
        )
      } else {
        let delay = Self.retryDelaySeconds(attempt: attempt, jitterUnit: Double.random(in: 0...1))
        try await store.retryIngestionInbox(
          environment: item.environment,
          sourceGeneration: item.sourceGeneration,
          sequence: item.sequence,
          workerId: workerId,
          leaseToken: item.leaseToken,
          failureCategory: category,
          failureReason: reason,
          nextAttemptAt: Date().addingTimeInterval(delay),
          at: Date()
        )
        logger.warning(
          "Jetstream V2 inbox event scheduled for retry",
          metadata: [
            "sequence": .stringConvertible(item.sequence),
            "event_kind": .string(item.eventKind.rawValue),
            "attempt": .stringConvertible(attempt),
            "retry_seconds": .stringConvertible(delay),
            "error_type": .string(category),
          ]
        )
      }
    } catch {
      // The lease remains fenced and will be recovered after expiry if failure persistence fails.
      logger.error(
        "Failed to persist Jetstream V2 inbox retry state",
        metadata: [
          "sequence": .stringConvertible(item.sequence),
          "error_type": .string(Self.failureCategory(error)),
        ]
      )
    }
  }

  static func retryDelaySeconds(attempt: Int, jitterUnit: Double) -> TimeInterval {
    let exponent = min(max(0, attempt - 1), 7)
    let base = min(30, 0.25 * pow(2, Double(exponent)))
    return min(30, base + (base * 0.25 * min(1, max(0, jitterUnit))))
  }

  private static func lane(for did: String, count: Int) -> Int {
    did.utf8.reduce(into: 0) { result, byte in
      result = (result &* 31 &+ Int(byte)) % count
    }
  }

  private static func failureCategory(_ error: any Error) -> String {
    String(reflecting: type(of: error))
      .split(separator: ".")
      .last
      .map(String.init) ?? "unknown_error"
  }

  private static func validateNormalizedMetadata(
    _ item: AppViewIngestionInboxItem,
    event: JetstreamV2ProjectionEvent
  ) throws {
    guard case .commit(let commit) = event else { return }
    guard item.collection == nil || item.collection == commit.collection,
      item.operation == nil || item.operation == commit.operation.rawValue,
      item.repoRev == nil || item.repoRev == commit.repoRev,
      item.recordKey == nil || item.recordKey == commit.rkey,
      item.recordCID == nil || item.recordCID == commit.cid
    else { throw JetstreamV2ProjectionEventParseError.metadataMismatch }
  }
}

public enum JetstreamInboxProjectionError: Error, Sendable, Equatable {
  case commitRecordUnavailable
  case projectionTimedOut
  case repositoryReconciliationUnavailable
  case repositoryReconciliationIncomplete
}
