import Foundation
import Logging
import OperationsCore

struct ThinAppViewRecoveryJobRunner: Sendable {
  private static let leaseDuration: TimeInterval = 60
  private static let leaseHeartbeatInterval: TimeInterval = 5

  let store: any OperationsStore
  let indexer: ThinAppViewIndexer
  let pdsBackfill: ThinAppViewEnrollBackfill
  let relayURL: String
  let workerId: String
  let logger: Logger

  func runForever() async {
    while !Task.isCancelled {
      do {
        let now = Date()
        if let job = try await store.claimNextBackfill(
          workerId: workerId,
          leaseUntil: now.addingTimeInterval(Self.leaseDuration),
          at: now
        ) {
          try await execute(job)
        } else {
          try await Task.sleep(for: .seconds(5))
        }
      } catch {
        logger.error(
          "Recovery job poll failed",
          metadata: ["error_type": .string(OperationsRedactor.errorCategory(error))]
        )
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func execute(_ claimedJob: BackfillJob) async throws {
    let lease = OwnedBackfillLease(
      store: store,
      job: claimedJob,
      workerId: workerId,
      leaseDuration: Self.leaseDuration
    )
    let heartbeat = Task {
      await lease.heartbeatForever(interval: Self.leaseHeartbeatInterval)
    }
    defer { heartbeat.cancel() }

    do {
      switch claimedJob.sourceMode {
      case .tapVerifiedResync:
        // The pinned upstream Tap has no safe operator resync endpoint. `/repos/remove` followed by
        // `/repos/add` deletes Tap's repository and resync-buffer state, and `/info/:did` exposes no
        // job-scoped validation watermark or complete-delete proof. Keep this fail-closed until Tap
        // can provide those contracts; never manufacture verified evidence from repository state.
        throw TapVerifiedResyncUnavailableError()

      case .pdsReconciliation:
        try await executePDSReconciliation(claimedJob, lease: lease)

      case .jetstreamReplay:
        let progress = RecoveryProgress(job: claimedJob)
        let executor = JetstreamReplayExecutor(
          relayURL: relayURL,
          indexer: indexer,
          store: store,
          job: claimedJob,
          lease: lease,
          progress: progress,
          logger: logger
        )
        try await executor.run()
        let snapshot = await progress.snapshot()
        _ = try await lease.checkpoint(snapshot)
        _ = try await lease.recordVerification(
          exactScope: false,
          truncated: false,
          failedCount: snapshot.failed,
          validationWatermark: nil
        )
      }

      try await lease.complete()
    } catch RecoveryControlError.stopped {
      return
    } catch {
      // A pause/cancel/lease steal increments the version and makes this transition fail. That is
      // intentional: stale workers must not overwrite the operator's newer state.
      try? await lease.fail(reason: OperationsRedactor.errorCategory(error))
      throw error
    }
  }

  private func executePDSReconciliation(
    _ job: BackfillJob,
    lease: OwnedBackfillLease
  ) async throws {
    let progress = RecoveryProgress(job: job)
    let report = try await pdsBackfill.reconcile(
      authorDids: job.authorDids,
      collections: job.collections,
      options: pdsBackfill.diagnosticOptions(
        maxConcurrency: job.maxConcurrency,
        rateLimitPerSecond: job.rateLimit
      ),
      shouldContinue: { await lease.canContinue },
      onProgress: { _ in
        let snapshot = await progress.recordReconciled()
        guard snapshot.processed.isMultiple(of: max(1, job.batchSize)) else { return }
        do {
          _ = try await lease.checkpoint(snapshot)
        } catch {
          await lease.stopWork()
        }
      }
    )
    guard await lease.canContinue else { throw RecoveryControlError.stopped }

    _ = try await lease.recordAuthorResults(Self.authorResults(report))

    let issues = Self.reconciliationFailures(report)
    if !issues.isEmpty {
      await progress.recordFailures(issues.count)
      for issue in issues {
        try? await store.recordRecoveryFailure(
          jobId: job.id,
          identityHash: OperationsRedactor.hashIdentity(issue.identity),
          collection: issue.collection,
          operation: "pds_reconciliation",
          cursor: nil,
          errorCategory: issue.category,
          at: Date()
        )
      }
    }

    let snapshot = await progress.snapshot()
    _ = try await lease.checkpoint(snapshot)
    _ = try await lease.recordVerification(
      exactScope: false,
      truncated: report.truncated,
      failedCount: snapshot.failed,
      validationWatermark: nil
    )
  }

  private static func reconciliationFailures(
    _ report: PDSReconciliationReport
  ) -> [(identity: String, collection: String, category: String)] {
    var failures = report.authorScope.issues.map {
      (
        identity: "scope/\($0.value)",
        collection: "*",
        category: $0.kind.rawValue
      )
    }
    failures.append(contentsOf: report.unsupportedCollections.map {
      (identity: "unsupported/\($0)", collection: $0, category: "unsupported_collection")
    })
    for author in report.authors {
      failures.append(
        contentsOf: author.issues.map {
          (identity: author.authorDid, collection: "*", category: $0.kind.rawValue)
        }
      )
      for collection in author.collections {
        failures.append(
          contentsOf: collection.issues.map {
            (
              identity: "\(author.authorDid)/\(collection.collection)",
              collection: collection.collection,
              category: $0.kind.rawValue
            )
          }
        )
      }
    }
    return failures
  }

  static func authorResults(
    _ report: PDSReconciliationReport
  ) -> [BackfillAuthorResult] {
    var results: [BackfillAuthorResult] = []
    for author in report.authors {
      if !author.issues.isEmpty {
        let errors = normalizedIssueKinds(author.issues)
        results.append(
          BackfillAuthorResult(
            did: author.authorDid,
            collection: "*",
            discoveredCount: 0,
            processedCount: 0,
            failedCount: 0,
            capped: false,
            truncated: false,
            status: errors.contains(PDSReconciliationIssueKind.cancelled.rawValue)
              ? .cancelled : .failed,
            error: errors.joined(separator: ",")
          )
        )
      }
      for collection in author.collections {
        let errors = normalizedIssueKinds(collection.issues)
        let failedCount = max(0, collection.observedCount - collection.indexedCount)
        let capped = collection.issues.contains { $0.kind == .recordCapReached }
        let status: BackfillAuthorResultStatus
        if collection.issues.contains(where: { $0.kind == .cancelled }) {
          status = .cancelled
        } else if collection.issues.isEmpty, !collection.truncated, failedCount == 0 {
          status = .succeeded
        } else if collection.indexedCount == 0, !capped {
          status = .failed
        } else {
          status = .partial
        }
        results.append(
          BackfillAuthorResult(
            did: author.authorDid,
            collection: collection.collection,
            discoveredCount: collection.observedCount,
            processedCount: collection.indexedCount,
            failedCount: failedCount,
            capped: capped,
            truncated: collection.truncated,
            status: status,
            error: errors.isEmpty ? nil : errors.joined(separator: ",")
          )
        )
      }
      for collection in report.unsupportedCollections {
        results.append(
          BackfillAuthorResult(
            did: author.authorDid,
            collection: collection,
            discoveredCount: 0,
            processedCount: 0,
            failedCount: 0,
            capped: false,
            truncated: false,
            status: .unsupported,
            error: PDSReconciliationIssueKind.unsupportedCollection.rawValue
          )
        )
      }
    }
    return results.sorted {
      ($0.did, $0.collection) < ($1.did, $1.collection)
    }
  }

  private static func normalizedIssueKinds(
    _ issues: [PDSReconciliationIssue]
  ) -> [String] {
    Array(Set(issues.map { $0.kind.rawValue })).sorted()
  }
}

private struct TapVerifiedResyncUnavailableError: Error {}
private enum RecoveryControlError: Error { case stopped, replayComplete }
private struct ReplayIncompleteError: Error {}
private struct ReplayRequiresUpperBoundError: Error {}

private struct RecoveryProgressSnapshot: Sendable {
  let cursor: Int64?
  let processed: Int
  let failed: Int
  let reconciled: Int
}

private actor RecoveryProgress {
  private var cursor: Int64?
  private var processed: Int
  private var failed: Int
  private var reconciled: Int

  init(job: BackfillJob) {
    cursor = job.checkpointCursor
    processed = job.processedCount
    failed = job.failedCount
    reconciled = job.reconciledCount
  }

  func recordReconciled(cursor: Int64? = nil) -> RecoveryProgressSnapshot {
    processed += 1
    reconciled += 1
    if let cursor { self.cursor = cursor }
    return snapshot()
  }

  func recordFailure() -> RecoveryProgressSnapshot {
    processed += 1
    failed += 1
    return snapshot()
  }

  func recordFailures(_ count: Int) {
    processed += count
    failed += count
  }

  func snapshot() -> RecoveryProgressSnapshot {
    RecoveryProgressSnapshot(
      cursor: cursor,
      processed: processed,
      failed: failed,
      reconciled: reconciled
    )
  }
}

/// Serializes lease-version mutations. Swift actors are reentrant across `await`, so an explicit
/// mutation gate is required to prevent a heartbeat and checkpoint from racing on the same version.
private actor OwnedBackfillLease {
  private let store: any OperationsStore
  private let workerId: String
  private let leaseDuration: TimeInterval
  private var job: BackfillJob
  private var workMayContinue = true
  private var mutationInFlight = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    store: any OperationsStore,
    job: BackfillJob,
    workerId: String,
    leaseDuration: TimeInterval
  ) {
    self.store = store
    self.job = job
    self.workerId = workerId
    self.leaseDuration = leaseDuration
  }

  var canContinue: Bool { workMayContinue && job.status == .running }

  func stopWork() {
    workMayContinue = false
  }

  func heartbeatForever(interval: TimeInterval) async {
    while !Task.isCancelled, canContinue {
      do {
        try await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, canContinue else { return }
        try await beginMutation()
        defer { endMutation() }
        let now = Date()
        do {
          job = try await store.renewBackfillLease(
            id: job.id,
            workerId: workerId,
            expectedVersion: job.version,
            leaseUntil: now.addingTimeInterval(leaseDuration),
            at: now
          )
        } catch {
          workMayContinue = false
          return
        }
      } catch {
        return
      }
    }
  }

  func checkpoint(_ progress: RecoveryProgressSnapshot) async throws -> BackfillJob {
    try await beginMutation()
    defer { endMutation() }
    guard canContinue else { throw RecoveryControlError.stopped }
    let now = Date()
    do {
      job = try await store.checkpointBackfill(
        id: job.id,
        workerId: workerId,
        expectedVersion: job.version,
        cursor: progress.cursor,
        processed: progress.processed,
        failed: progress.failed,
        reconciled: progress.reconciled,
        leaseUntil: now.addingTimeInterval(leaseDuration),
        at: now
      )
      return job
    } catch {
      workMayContinue = false
      throw error
    }
  }

  func recordVerification(
    exactScope: Bool,
    truncated: Bool,
    failedCount: Int,
    validationWatermark: String?
  ) async throws -> BackfillJob {
    try await beginMutation()
    defer { endMutation() }
    guard canContinue else { throw RecoveryControlError.stopped }
    do {
      job = try await store.recordBackfillVerification(
        id: job.id,
        workerId: workerId,
        expectedVersion: job.version,
        exactScope: exactScope,
        truncated: truncated,
        failedCount: failedCount,
        validationWatermark: validationWatermark,
        at: Date()
      )
      return job
    } catch {
      workMayContinue = false
      throw error
    }
  }

  func recordAuthorResults(_ results: [BackfillAuthorResult]) async throws -> BackfillJob {
    try await beginMutation()
    defer { endMutation() }
    guard canContinue else { throw RecoveryControlError.stopped }
    do {
      job = try await store.recordBackfillAuthorResults(
        id: job.id,
        workerId: workerId,
        expectedVersion: job.version,
        results: results,
        at: Date()
      )
      return job
    } catch {
      workMayContinue = false
      throw error
    }
  }

  func complete() async throws {
    try await transition(to: .completed, reason: nil)
  }

  func fail(reason: String) async throws {
    try await transition(to: .failed, reason: reason)
  }

  private func transition(to status: BackfillJobStatus, reason: String?) async throws {
    try await beginMutation()
    defer { endMutation() }
    guard job.status == .running else { throw RecoveryControlError.stopped }
    job = try await store.transitionBackfill(
      id: job.id,
      to: status,
      expectedVersion: job.version,
      operatorDid: "system:worker",
      idempotencyKey: "recovery:\(job.id):\(status.rawValue)",
      requestId: nil,
      note: nil,
      failureReason: reason,
      at: Date()
    )
    workMayContinue = false
  }

  private func beginMutation() async throws {
    try Task.checkCancellation()
    if mutationInFlight {
      await withCheckedContinuation { continuation in
        mutationWaiters.append(continuation)
      }
      if Task.isCancelled {
        // Ownership of the mutation gate transfers when the waiter resumes. Release it before
        // surfacing cancellation because the caller has not installed its `defer` yet.
        endMutation()
        throw CancellationError()
      }
    } else {
      mutationInFlight = true
    }
  }

  private func endMutation() {
    if mutationWaiters.isEmpty {
      mutationInFlight = false
    } else {
      mutationWaiters.removeFirst().resume()
    }
  }
}

private struct JetstreamReplayExecutor: Sendable {
  private static let noProgressTimeout: TimeInterval = 30

  let relayURL: String
  let indexer: ThinAppViewIndexer
  let store: any OperationsStore
  let job: BackfillJob
  let lease: OwnedBackfillLease
  let progress: RecoveryProgress
  let logger: Logger

  func run() async throws {
    guard job.endCursor != nil else { throw ReplayRequiresUpperBoundError() }
    let window = JetstreamReplayWindow(
      lowerBound: job.checkpointCursor ?? job.startCursor ?? 0,
      upperBound: job.endCursor
    )
    let policy = JetstreamReplayEnvelopePolicy(
      window: window,
      authorDids: job.authorDids,
      collections: job.collections
    )
    let progressMonitor = JetstreamReplayProgressMonitor(
      initialCursor: window.connectionCursor,
      timeout: Self.noProgressTimeout
    )
    let replayURL = try JetstreamCursor.url(relayURL, cursor: window.connectionCursor)
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          #if canImport(WebSocketKit)
            try await FirehoseLinuxWebSocket.consume(
              relayURL: replayURL,
              logger: logger,
              onConnected: {}
            ) { text in
              try await handle(text, policy: policy, progressMonitor: progressMonitor)
            }
          #else
            try await FirehoseSubscriberURLSessionTransport.consume(
              relayURL: replayURL,
              logger: logger,
              isCancelled: { Task.isCancelled },
              onConnected: {}
            ) { text in
              try await handle(text, policy: policy, progressMonitor: progressMonitor)
            }
          #endif
        }
        group.addTask {
          try await progressMonitor.waitForStall()
        }
        _ = try await group.next()
        group.cancelAll()
      }
    } catch RecoveryControlError.replayComplete {
      return
    }
    throw ReplayIncompleteError()
  }

  private func handle(
    _ text: String,
    policy: JetstreamReplayEnvelopePolicy,
    progressMonitor: JetstreamReplayProgressMonitor
  ) async throws {
    guard await lease.canContinue else { throw RecoveryControlError.stopped }
    guard
      let data = text.data(using: .utf8),
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    let cursor: Int64
    switch policy.classifyCursor(json) {
    case .missing:
      return
    case .pastUpperBound(let value):
      await progressMonitor.observe(cursor: value)
      throw RecoveryControlError.replayComplete
    case .beforeWindow(let value):
      await progressMonitor.observe(cursor: value)
      return
    case .withinWindow(let value):
      cursor = value
      await progressMonitor.observe(cursor: value)
    }

    guard
      (json["kind"] as? String) == "commit",
      let did = json["did"] as? String,
      let commit = json["commit"] as? [String: Any],
      let collection = commit["collection"] as? String,
      policy.includes(did: did, collection: collection),
      let rkey = commit["rkey"] as? String,
      let operation = commit["operation"] as? String
    else { return }
    let record = commit["record"] ?? [:]
    let recordJSON = (try? JSONSerialization.data(withJSONObject: record)) ?? Data("{}".utf8)
    do {
      let intervalNanoseconds = Int64(1_000_000_000 / max(1, job.rateLimit))
      try await Task.sleep(for: .nanoseconds(intervalNanoseconds))
      try await indexer.handleCommit(
        repoDid: did,
        collection: collection,
        rkey: rkey,
        cid: commit["cid"] as? String ?? "",
        recordJSON: recordJSON,
        operation: operation,
        ingestionSource: "jetstream_replay_unverified",
        cursor: String(cursor),
        eventTime: Date(timeIntervalSince1970: Double(cursor) / 1_000_000)
      )
      let snapshot = await progress.recordReconciled(cursor: cursor)
      if snapshot.processed.isMultiple(of: max(1, job.batchSize)) {
        _ = try await lease.checkpoint(snapshot)
      }
    } catch RecoveryControlError.stopped {
      throw RecoveryControlError.stopped
    } catch {
      try? await store.recordRecoveryFailure(
        jobId: job.id,
        identityHash: OperationsRedactor.hashIdentity("\(did)/\(collection)/\(rkey)"),
        collection: collection,
        operation: operation,
        cursor: cursor,
        errorCategory: OperationsRedactor.errorCategory(error),
        at: Date()
      )
      // The failed cursor was not committed. Persist only the cursor already held by progress.
      let failedSnapshot = await progress.recordFailure()
      _ = try? await lease.checkpoint(failedSnapshot)
      throw error
    }
  }
}

struct JetstreamReplayWindow: Equatable, Sendable {
  let lowerBound: Int64
  let upperBound: Int64?

  var connectionCursor: Int64 { max(0, lowerBound - 5_000_000) }

  func contains(_ cursor: Int64) -> Bool {
    guard cursor > lowerBound else { return false }
    return upperBound.map { cursor <= $0 } ?? true
  }

  func isPastUpperBound(_ cursor: Int64) -> Bool {
    upperBound.map { cursor > $0 } ?? false
  }
}
