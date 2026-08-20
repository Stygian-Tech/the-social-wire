import Foundation
import Logging
import OperationsCore

public final class JetstreamInboxProjectionWorker: Sendable {
  private struct CommitMeasurement: Sendable {
    let collection: String
    let operation: String
    let eventTime: Date
    let indexingResult: String
    let didMutateProjection: Bool
    let startedAt: Date
  }

  private let store: any ThinAppViewStore
  private let indexers: [ThinAppViewIndexer]
  private let repositoryRestorer: (any TapRepositoryRestorer)?
  private let environment: String
  private let sourceGeneration: String
  private let intakeLeaseName: String
  private let workerId: String
  private let maxConcurrency: Int
  private let reconciliationMaxConcurrency: Int
  private let refillBatchSize: Int
  private let leaseSeconds: TimeInterval
  private let pollMilliseconds: Int
  private let appliedRetentionSeconds: TimeInterval
  private let deadLetterRetentionSeconds: TimeInterval
  private let projectionTimeoutSeconds: TimeInterval
  private let scopeFilterBatchSize: Int
  private let telemetry: OperationsTelemetryBuffer?
  private let logger: Logger

  public init(
    store: any ThinAppViewStore,
    indexers: [ThinAppViewIndexer],
    repositoryRestorer: (any TapRepositoryRestorer)? = nil,
    environment: String,
    sourceGeneration: String,
    intakeLeaseName: String = ThinAppViewConfig.defaultJetstreamLeaderLeaseName,
    workerId: String,
    maxConcurrency: Int,
    leaseSeconds: TimeInterval,
    pollMilliseconds: Int,
    appliedRetentionSeconds: TimeInterval,
    deadLetterRetentionSeconds: TimeInterval,
    projectionTimeoutSeconds: TimeInterval = 120,
    reconciliationMaxConcurrency: Int = 2,
    scopeFilterBatchSize: Int = 1_000,
    telemetry: OperationsTelemetryBuffer? = nil,
    logger: Logger
  ) {
    precondition(!indexers.isEmpty, "At least one ThinAppViewIndexer is required.")
    self.store = store
    self.indexers = indexers
    self.repositoryRestorer = repositoryRestorer
    self.environment = environment
    self.sourceGeneration = sourceGeneration
    self.intakeLeaseName = intakeLeaseName
    self.workerId = workerId
    self.maxConcurrency = max(1, min(maxConcurrency, indexers.count))
    self.reconciliationMaxConcurrency = max(
      1,
      min(reconciliationMaxConcurrency, self.maxConcurrency)
    )
    self.refillBatchSize = max(1, min(8, self.maxConcurrency / 4))
    self.leaseSeconds = max(5, leaseSeconds)
    self.pollMilliseconds = max(25, pollMilliseconds)
    self.appliedRetentionSeconds = max(60, appliedRetentionSeconds)
    self.deadLetterRetentionSeconds = max(60, deadLetterRetentionSeconds)
    self.projectionTimeoutSeconds = max(0.01, projectionTimeoutSeconds)
    self.scopeFilterBatchSize = max(1, min(scopeFilterBatchSize, 10_000))
    self.telemetry = telemetry
    self.logger = logger
  }

  public func runForever() async {
    logger.info(
      "Starting durable Jetstream V2 inbox projection",
      metadata: [
        "source_generation": .string(sourceGeneration),
        "max_concurrency": .stringConvertible(maxConcurrency),
        "reconciliation_max_concurrency": .stringConvertible(reconciliationMaxConcurrency),
        "refill_batch_size": .stringConvertible(refillBatchSize),
        "scope_filter_batch_size": .stringConvertible(scopeFilterBatchSize),
      ]
    )
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.runLiveForever() }
      if repositoryRestorer != nil {
        group.addTask { await self.runReconciliationForever() }
      }
      await group.waitForAll()
    }
  }

  private func runLiveForever() async {
    while !Task.isCancelled {
      do {
        let claimed = try await drainLiveUntilIdle()
        if claimed == 0 {
          try await Task.sleep(for: .milliseconds(pollMilliseconds))
        }
      } catch is CancellationError {
        if Self.shouldStopLoopAfterCancellation(parentTaskIsCancelled: Task.isCancelled) {
          return
        }
        logger.error("Jetstream V2 inbox projection loop received unexpected cancellation")
        try? await Task.sleep(for: .seconds(1))
      } catch {
        logger.error(
          "Jetstream V2 inbox projection loop failed",
          metadata: ["error_type": .string(Self.failureCategory(error))]
        )
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  @discardableResult
  public func drainOnce(at now: Date = Date()) async throws -> Int {
    guard repositoryRestorer != nil else {
      return try await drainLiveUntilIdle(at: now)
    }
    async let live = drainLiveUntilIdle(at: now)
    async let reconciliations = drainReconciliationsUntilIdle(at: now)
    let counts = try await (live, reconciliations)
    // Preserve the one-shot contract: reconciliation may remove the final watermark/incident
    // barrier after the live drain's last durability pass.
    try await advanceDurabilityEvidence(at: Date())
    return counts.0 + counts.1
  }

  func drainLiveUntilIdle(
    at initialNow: Date = Date(),
    claimObserver: (@Sendable (_ requestedLimit: Int, _ claimedCount: Int) async -> Void)? = nil
  ) async throws -> Int {
    var filteredCount = 0
    while true {
      try Task.checkCancellation()
      let batchCount = try await store.filterIngestionInboxOutsideScope(
        environment: environment,
        sourceGeneration: sourceGeneration,
        policy: AppViewIngestionScopePolicy.version,
        limit: scopeFilterBatchSize,
        expiresAt: initialNow.addingTimeInterval(appliedRetentionSeconds),
        at: initialNow
      )
      filteredCount += batchCount
      if batchCount < scopeFilterBatchSize { break }
    }
    return try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
      var inFlight = 0
      var claimedCount = 0
      var completedSinceWatermark = 0
      var isInitialClaim = true
      var pendingError: (any Error)?
      var refillAllowed = true
      defer { group.cancelAll() }

      while true {
        try Task.checkCancellation()
        let available = maxConcurrency - inFlight
        if pendingError == nil, refillAllowed,
          inFlight == 0 || available >= refillBatchSize
        {
          let limit = inFlight == 0 ? maxConcurrency : min(available, refillBatchSize)
          do {
            let claimAt = isInitialClaim ? initialNow : Date()
            let items = try await claimLiveItems(limit: limit, at: claimAt)
            await claimObserver?(limit, items.count)
            isInitialClaim = false
            claimedCount += items.count
            inFlight += items.count
            for item in items {
              let indexer = indexers[Self.lane(for: item.repoDid, count: indexers.count)]
              group.addTask { await self.process(item, with: indexer) }
            }
          } catch {
            pendingError = error
          }
        }

        guard inFlight > 0 else { break }
        if try await group.next() == false {
          // Do not reclaim a retry produced by this drain even when a database rounds its
          // next-attempt timestamp. A later outer-loop iteration owns the backoff boundary.
          refillAllowed = false
        }
        inFlight -= 1
        completedSinceWatermark += 1
        if completedSinceWatermark >= maxConcurrency, pendingError == nil {
          do {
            try await advanceDurabilityEvidence(at: Date())
            completedSinceWatermark = 0
          } catch {
            pendingError = error
          }
        }
      }

      try Task.checkCancellation()
      if pendingError == nil {
        try await advanceDurabilityEvidence(at: Date())
      }
      if let pendingError { throw pendingError }
      return filteredCount + claimedCount
    }
  }

  private func claimLiveItems(
    limit: Int,
    at now: Date
  ) async throws -> [AppViewIngestionInboxItem] {
    try await store.claimIngestionInbox(
      environment: environment,
      sourceGeneration: sourceGeneration,
      workerId: workerId,
      limit: limit,
      leaseUntil: now.addingTimeInterval(leaseSeconds),
      at: now
    )
  }

  private func advanceDurabilityEvidence(at now: Date) async throws {
    try await store.advanceIngestionInboxAppliedWatermark(
      environment: environment,
      sourceGeneration: sourceGeneration,
      at: now
    )
    _ = try await store.resolveRecoveredIngestionIncidents(
      environment: environment,
      sourceGeneration: sourceGeneration,
      at: now
    )
    _ = try await store.resolveTerminalRetiredGenerationIncidents(
      environment: environment,
      activeSourceGeneration: sourceGeneration,
      activeLeaseName: intakeLeaseName,
      at: now
    )
  }

  private func runReconciliationForever() async {
    while !Task.isCancelled {
      do {
        let claimed = try await drainReconciliationsUntilIdle()
        if claimed == 0 {
          try await Task.sleep(for: .milliseconds(pollMilliseconds))
        }
      } catch is CancellationError {
        if Self.shouldStopLoopAfterCancellation(parentTaskIsCancelled: Task.isCancelled) {
          return
        }
        logger.error("Jetstream V2 reconciliation loop received unexpected cancellation")
        try? await Task.sleep(for: .seconds(1))
      } catch {
        logger.error(
          "Jetstream V2 reconciliation loop failed",
          metadata: ["error_type": .string(Self.failureCategory(error))]
        )
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func drainReconciliationsUntilIdle(at initialNow: Date = Date()) async throws -> Int {
    guard repositoryRestorer != nil else { return 0 }
    return try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
      var inFlight = 0
      var claimedCount = 0
      var isInitialClaim = true
      var pendingError: (any Error)?
      var refillAllowed = true
      defer { group.cancelAll() }

      while true {
        try Task.checkCancellation()
        let available = reconciliationMaxConcurrency - inFlight
        if pendingError == nil, refillAllowed, available > 0 {
          do {
            let claimAt = isInitialClaim ? initialNow : Date()
            let requests = try await store.claimIngestionReconciliationRequests(
              environment: environment,
              sourceGeneration: sourceGeneration,
              workerId: workerId,
              limit: available,
              leaseUntil: claimAt.addingTimeInterval(leaseSeconds),
              at: claimAt
            )
            isInitialClaim = false
            claimedCount += requests.count
            inFlight += requests.count
            for request in requests {
              group.addTask { await self.processReconciliation(request) }
            }
          } catch {
            pendingError = error
          }
        }

        guard inFlight > 0 else { break }
        if try await group.next() == false {
          refillAllowed = false
        }
        inFlight -= 1
      }

      try Task.checkCancellation()
      if let pendingError { throw pendingError }
      return claimedCount
    }
  }

  private func process(
    _ item: AppViewIngestionInboxItem,
    with indexer: ThinAppViewIndexer
  ) async -> Bool {
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
      return true
    } catch is CancellationError {
      return false
    } catch {
      await emitCommitFailureMetric(item: item, error: error)
      return await handleFailure(error, item: item)
    }
  }

  private func apply(
    _ item: AppViewIngestionInboxItem,
    with indexer: ThinAppViewIndexer
  ) async throws {
    let startedAt = Date()
    var commitMeasurement: CommitMeasurement?
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
      let indexingOutcome = try await indexer.handleCommitWithOutcome(
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
      commitMeasurement = CommitMeasurement(
        collection: commit.collection,
        operation: commit.operation.rawValue,
        eventTime: commit.eventTime,
        indexingResult: indexingOutcome.didMutateProjection ? "indexed" : "skipped",
        didMutateProjection: indexingOutcome.didMutateProjection,
        startedAt: startedAt
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
    if let commitMeasurement {
      await emitCommitSuccessMetrics(commitMeasurement)
    }
  }

  private func emitCommitSuccessMetrics(_ measurement: CommitMeasurement) async {
    let commonDimensions = [
      "collection": Self.collectionDimension(measurement.collection),
      "operation": measurement.operation,
      "ingestion_mode": "live",
    ]
    if measurement.didMutateProjection {
      await emitMetric(
        "socialwire.ingestion.events_total",
        value: 1,
        dimensions: commonDimensions
      )
      await emitMetric(
        "socialwire.ingestion.db_write_duration_seconds",
        value: Date().timeIntervalSince(measurement.startedAt),
        dimensions: commonDimensions
      )
    }
    await emitMetric(
      "socialwire.ingestion.results_total",
      value: 1,
      dimensions: commonDimensions.merging([
        "result": "success",
        "indexing_result": measurement.indexingResult,
      ]) { _, new in new }
    )
    await emitMetric(
      "socialwire.ingestion.commit_lag_seconds",
      value: Date().timeIntervalSince(measurement.eventTime),
      dimensions: [
        "collection": Self.collectionDimension(measurement.collection),
        "ingestion_mode": "live",
      ]
    )
  }

  private func emitCommitFailureMetric(
    item: AppViewIngestionInboxItem,
    error: any Error
  ) async {
    guard item.eventKind == .commit,
      let collection = item.collection,
      let operation = item.operation
    else { return }
    await emitMetric(
      "socialwire.ingestion.results_total",
      value: 1,
      dimensions: [
        "collection": Self.collectionDimension(collection),
        "operation": operation,
        "result": "error",
        "error_type": OperationsRedactor.errorCategory(error),
        "ingestion_mode": "live",
      ]
    )
  }

  private func emitMetric(
    _ name: String,
    value: Double,
    dimensions: [String: String]
  ) async {
    _ = await telemetry?.enqueue(.metric(.init(
      name: name,
      value: value,
      dimensions: dimensions
    )))
  }

  private static func collectionDimension(_ value: String) -> String {
    let allowlist: Set<String> = [
      "site.standard.document", "site.standard.entry", "site.standard.publication",
      "site.standard.graph.subscription",
      "app.skyreader.feed.subscription", "app.thesocialwire.entryReadState",
    ]
    return allowlist.contains(value) ? value : "other"
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

  private func processReconciliation(
    _ request: AppViewIngestionReconciliationRequest
  ) async -> Bool {
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
      return true
    } catch is CancellationError {
      return false
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
        return false
      } catch {
        logger.error(
          "Failed to persist targeted repository reconciliation retry",
          metadata: ["request_id": .string(request.id)])
        return false
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

  private func handleFailure(_ error: any Error, item: AppViewIngestionInboxItem) async -> Bool {
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
        return true
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
        return false
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
      return false
    }
  }

  static func retryDelaySeconds(attempt: Int, jitterUnit: Double) -> TimeInterval {
    let exponent = min(max(0, attempt - 1), 7)
    let base = min(30, 0.25 * pow(2, Double(exponent)))
    return min(30, base + (base * 0.25 * min(1, max(0, jitterUnit))))
  }

  static func shouldStopLoopAfterCancellation(parentTaskIsCancelled: Bool) -> Bool {
    parentTaskIsCancelled
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
