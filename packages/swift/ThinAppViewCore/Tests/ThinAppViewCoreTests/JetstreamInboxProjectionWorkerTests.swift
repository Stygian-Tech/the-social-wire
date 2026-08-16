import Foundation
@preconcurrency import GRDB
import Logging
import Testing
@testable import ThinAppViewCore

@Suite("Durable Jetstream V2 inbox")
struct JetstreamInboxProjectionWorkerTests {
  @Test("local inbox schema preserves incident source host identity")
  func localIncidentSchemaIncludesSourceHost() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let columns = try fixture.database.read { database in
      try String.fetchAll(
        database,
        sql: "SELECT name FROM pragma_table_info('appview_ingestion_incidents')"
      )
    }
    #expect(columns.contains("source_host"))
  }

  @Test("claims one event per DID and recovers only expired leases")
  func claimPreservesRepositoryFIFOAndLeaseFencing() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.seedCheckpoint(lastStagedSequence: 100, at: now)
    try fixture.seedEvent(sequence: 10, did: "did:plc:a", payload: Self.identityPayload(10, did: "did:plc:a"), at: now)
    try fixture.seedEvent(sequence: 20, did: "did:plc:a", payload: Self.identityPayload(20, did: "did:plc:a"), at: now)
    try fixture.seedEvent(sequence: 100, did: "did:plc:b", payload: Self.identityPayload(100, did: "did:plc:b"), at: now)

    let first = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "worker-a",
      limit: 8,
      leaseUntil: now.addingTimeInterval(60),
      at: now
    )
    #expect(first.map(\.sequence) == [10, 100])
    #expect(Set(first.map(\.repoDid)) == ["did:plc:a", "did:plc:b"])

    let beforeExpiry = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "worker-b",
      limit: 8,
      leaseUntil: now.addingTimeInterval(90),
      at: now.addingTimeInterval(30)
    )
    #expect(beforeExpiry.isEmpty)

    let recovered = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "worker-b",
      limit: 8,
      leaseUntil: now.addingTimeInterval(180),
      at: now.addingTimeInterval(90)
    )
    #expect(recovered.map(\.sequence) == [10, 100])
    #expect(recovered[0].leaseToken != first[0].leaseToken)
    await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
      try await fixture.store.markIngestionInboxApplied(
        environment: "dev",
        sourceGeneration: Fixture.generation,
        sequence: first[0].sequence,
        workerId: "worker-a",
        leaseToken: first[0].leaseToken,
        expiresAt: now.addingTimeInterval(7 * 86_400),
        at: now.addingTimeInterval(91)
      )
    }
  }

  @Test("applied watermark advances only across the terminal staged prefix")
  func appliedWatermarkIsATerminalPrefix() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.seedCheckpoint(lastStagedSequence: 100, at: now)
    try fixture.seedEvent(sequence: 10, did: "did:plc:a", payload: Self.identityPayload(10, did: "did:plc:a"), at: now)
    try fixture.seedEvent(sequence: 20, did: "did:plc:a", payload: Self.identityPayload(20, did: "did:plc:a"), at: now)
    try fixture.seedEvent(sequence: 100, did: "did:plc:b", payload: Self.identityPayload(100, did: "did:plc:b"), at: now)

    let first = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "worker",
      limit: 8,
      leaseUntil: now.addingTimeInterval(60),
      at: now
    )
    let high = try #require(first.first { $0.sequence == 100 })
    try await fixture.store.markIngestionInboxApplied(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: high.sequence,
      workerId: "worker",
      leaseToken: high.leaseToken,
      expiresAt: now.addingTimeInterval(7 * 86_400),
      at: now
    )
    #expect(try fixture.appliedWatermark() == nil)
    try await fixture.store.advanceIngestionInboxAppliedWatermark(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      at: now
    )
    #expect(try fixture.appliedWatermark() == nil)

    let low = try #require(first.first { $0.sequence == 10 })
    try await fixture.store.markIngestionInboxApplied(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: low.sequence,
      workerId: "worker",
      leaseToken: low.leaseToken,
      expiresAt: now.addingTimeInterval(7 * 86_400),
      at: now
    )
    #expect(try fixture.appliedWatermark() == nil)
    try await fixture.store.advanceIngestionInboxAppliedWatermark(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      at: now
    )
    #expect(try fixture.appliedWatermark() == 10)

    let second = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "worker",
      limit: 8,
      leaseUntil: now.addingTimeInterval(60),
      at: now
    )
    let middle = try #require(second.first)
    try await fixture.store.markIngestionInboxApplied(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: middle.sequence,
      workerId: "worker",
      leaseToken: middle.leaseToken,
      expiresAt: now.addingTimeInterval(7 * 86_400),
      at: now
    )
    #expect(try fixture.appliedWatermark() == 10)
    try await fixture.store.advanceIngestionInboxAppliedWatermark(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      at: now
    )
    #expect(try fixture.appliedWatermark() == 100)
  }

  @Test("an empty drain repairs a crash-lagged applied watermark")
  func emptyDrainRepairsCrashLaggedWatermark() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.seedCheckpoint(lastStagedSequence: 10, at: now)
    try fixture.seedEvent(
      sequence: 10,
      did: "did:plc:applied",
      payload: Self.identityPayload(10, did: "did:plc:applied"),
      at: now
    )
    let item = try #require(
      try await fixture.store.claimIngestionInbox(
        environment: "dev",
        sourceGeneration: Fixture.generation,
        workerId: "worker-before-crash",
        limit: 1,
        leaseUntil: now.addingTimeInterval(60),
        at: now
      ).first
    )
    try await fixture.store.markIngestionInboxApplied(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: item.sequence,
      workerId: "worker-before-crash",
      leaseToken: item.leaseToken,
      expiresAt: now.addingTimeInterval(7 * 86_400),
      at: now
    )
    #expect(try fixture.status(sequence: 10) == "applied")
    #expect(try fixture.appliedWatermark() == nil)

    #expect(try await fixture.worker().drainOnce(at: now.addingTimeInterval(1)) == 0)
    #expect(try fixture.appliedWatermark() == 10)
  }

  @Test("retry, leased, and unreconciled dead-letter rows remain watermark barriers")
  func actionableAndDeadLetterRowsRemainWatermarkBarriers() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.seedCheckpoint(lastStagedSequence: 40, at: now)
    for sequence in stride(from: Int64(10), through: 40, by: 10) {
      let did = "did:plc:barrier-\(sequence)"
      try fixture.seedEvent(
        sequence: sequence,
        did: did,
        payload: Self.identityPayload(sequence, did: did),
        at: now
      )
    }
    let claimed = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "worker",
      limit: 4,
      leaseUntil: now.addingTimeInterval(60),
      at: now
    )
    let bySequence = Dictionary(uniqueKeysWithValues: claimed.map { ($0.sequence, $0) })
    let applied = try #require(bySequence[10])
    let retrying = try #require(bySequence[20])
    let deadLetter = try #require(bySequence[40])

    try await fixture.store.markIngestionInboxApplied(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: applied.sequence,
      workerId: "worker",
      leaseToken: applied.leaseToken,
      expiresAt: now.addingTimeInterval(7 * 86_400),
      at: now
    )
    try await fixture.store.retryIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: retrying.sequence,
      workerId: "worker",
      leaseToken: retrying.leaseToken,
      failureCategory: "test",
      failureReason: "test",
      nextAttemptAt: now.addingTimeInterval(30),
      at: now
    )
    try await fixture.store.deadLetterIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: deadLetter.sequence,
      repoDid: deadLetter.repoDid,
      workerId: "worker",
      leaseToken: deadLetter.leaseToken,
      failureCategory: "test",
      failureReason: "test",
      expiresAt: now.addingTimeInterval(30 * 86_400),
      at: now
    )
    try await fixture.store.advanceIngestionInboxAppliedWatermark(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      at: now
    )

    #expect(try fixture.appliedWatermark() == 10)
    #expect(try fixture.status(sequence: 20) == "retry")
    #expect(try fixture.status(sequence: 30) == "leased")
    #expect(try fixture.status(sequence: 40) == "dead_letter")
  }

  @Test("worker advances the applied watermark once after a completed batch")
  func workerAdvancesWatermarkOncePerBatch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.seedCheckpoint(lastStagedSequence: 20, at: now)
    try fixture.seedEvent(
      sequence: 10,
      did: "did:plc:first",
      payload: Self.identityPayload(10, did: "did:plc:first"),
      at: now
    )
    try fixture.seedEvent(
      sequence: 20,
      did: "did:plc:second",
      payload: Self.identityPayload(20, did: "did:plc:second"),
      at: now
    )
    try fixture.installWatermarkUpdateCounter()

    #expect(try await fixture.worker().drainOnce(at: now) == 2)
    #expect(try fixture.appliedWatermark() == 20)
    #expect(try fixture.watermarkUpdateCount() == 1)
  }

  @Test("discarded lifecycle-only staging advances without inventing contiguous sequences")
  func advancesAcrossIntentionallyDiscardedEvents() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 9_999, at: now)

    try await fixture.store.advanceIngestionInboxAppliedWatermark(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      at: now
    )
    #expect(try fixture.appliedWatermark() == 9_999)
  }

  @Test("lease renewal prevents takeover and the old token is fenced after eventual reclaim")
  func leaseRenewalAndTakeoverAreFenced() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.seedCheckpoint(lastStagedSequence: 10, at: now)
    try fixture.seedEvent(sequence: 10, did: "did:plc:a", payload: Self.identityPayload(10, did: "did:plc:a"), at: now)
    let initial = try #require(
      try await fixture.store.claimIngestionInbox(
        environment: "dev",
        sourceGeneration: Fixture.generation,
        workerId: "worker-a",
        limit: 1,
        leaseUntil: now.addingTimeInterval(10),
        at: now
      ).first
    )
    try await fixture.store.renewIngestionInboxLease(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: initial.sequence,
      workerId: "worker-a",
      leaseToken: initial.leaseToken,
      leaseUntil: now.addingTimeInterval(100),
      at: now.addingTimeInterval(5)
    )
    let blocked = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "worker-b",
      limit: 1,
      leaseUntil: now.addingTimeInterval(120),
      at: now.addingTimeInterval(20)
    )
    #expect(blocked.isEmpty)
    let takeover = try #require(
      try await fixture.store.claimIngestionInbox(
        environment: "dev",
        sourceGeneration: Fixture.generation,
        workerId: "worker-b",
        limit: 1,
        leaseUntil: now.addingTimeInterval(200),
        at: now.addingTimeInterval(110)
      ).first
    )
    #expect(takeover.leaseToken != initial.leaseToken)
    await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
      try await fixture.store.markIngestionInboxApplied(
        environment: "dev",
        sourceGeneration: Fixture.generation,
        sequence: initial.sequence,
        workerId: "worker-a",
        leaseToken: initial.leaseToken,
        expiresAt: now.addingTimeInterval(7 * 86_400),
        at: now.addingTimeInterval(111)
      )
    }
  }

  @Test("rolling worker preserves same-DID order while refilling")
  func workerAppliesCommitThenAccountLifecycle() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    let did = "did:plc:author"
    try fixture.seedCheckpoint(lastStagedSequence: 102, at: now)
    try fixture.seedEvent(
      sequence: 101,
      did: did,
      kind: .commit,
      collection: "site.standard.entry",
      operation: "create",
      repoRev: "3kcreate",
      recordKey: "article",
      recordCID: "bafycreate",
      payload: Self.commitPayload(sequence: 101, did: did),
      at: now
    )
    try fixture.seedEvent(
      sequence: 102,
      did: did,
      kind: .account,
      payload: Self.accountPayload(102, did: did),
      at: now
    )
    let worker = fixture.worker()

    #expect(try await worker.drainOnce(at: now) == 2)
    let uri = "at://\(did)/site.standard.entry/article"
    #expect(try await fixture.store.fetchContentIdentity(uri: uri) == nil)
    #expect(try fixture.appliedWatermark() == 102)
  }

  @Test("tenth failure dead-letters and enqueues targeted reconciliation")
  func deadLettersPoisonEventAfterTenFailures() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 500, at: now)
    try fixture.seedEvent(
      sequence: 500,
      did: "did:plc:poison",
      kind: .commit,
      payload: "{}",
      attemptCount: 9,
      at: now
    )

    #expect(try await fixture.worker().drainOnce(at: now) == 1)
    #expect(try fixture.status(sequence: 500) == "dead_letter")
    #expect(try fixture.attemptCount(sequence: 500) == 10)
    #expect(try fixture.reconciliationRequestCount(sequence: 500) == 1)
    #expect(try fixture.appliedWatermark() == nil)
  }

  @Test("targeted reconciliation fences later inbox events for the same repository")
  func reconciliationRequestFencesLaterInboxEvents() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    let did = "did:plc:poison"
    try fixture.seedCheckpoint(lastStagedSequence: 501, at: now)
    try fixture.seedEvent(
      sequence: 500,
      did: did,
      kind: .commit,
      payload: "{}",
      attemptCount: 9,
      at: now
    )
    try fixture.seedEvent(
      sequence: 501,
      did: did,
      payload: Self.identityPayload(501, did: did),
      at: now
    )

    #expect(try await fixture.worker().drainOnce(at: now) == 1)
    let laterInbox = try await fixture.store.claimIngestionInbox(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "later-worker",
      limit: 1,
      leaseUntil: now.addingTimeInterval(60),
      at: now.addingTimeInterval(1)
    )
    let reconciliation = try await fixture.store.claimIngestionReconciliationRequests(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "reconciliation-worker",
      limit: 1,
      leaseUntil: now.addingTimeInterval(60),
      at: now.addingTimeInterval(1)
    )

    #expect(laterInbox.isEmpty)
    #expect(reconciliation.map(\.repoDid) == [did])
  }

  @Test("targeted reconciliation waits for an existing same-repository inbox lease")
  func reconciliationWaitsForExistingInboxLease() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    let did = "did:plc:leased"
    try fixture.seedCheckpoint(lastStagedSequence: 700, at: now)
    try fixture.seedEvent(
      sequence: 700,
      did: did,
      payload: Self.identityPayload(700, did: did),
      at: now
    )
    let leasedInbox = try #require(
      try await fixture.store.claimIngestionInbox(
        environment: "dev",
        sourceGeneration: Fixture.generation,
        workerId: "inbox-worker",
        limit: 1,
        leaseUntil: now.addingTimeInterval(60),
        at: now
      ).first
    )
    try fixture.seedReconciliationRequest(
      sequence: 699,
      did: did,
      at: now
    )

    let blocked = try await fixture.store.claimIngestionReconciliationRequests(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "reconciliation-worker",
      limit: 1,
      leaseUntil: now.addingTimeInterval(60),
      at: now.addingTimeInterval(1)
    )
    #expect(blocked.isEmpty)

    try await fixture.store.markIngestionInboxApplied(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      sequence: leasedInbox.sequence,
      workerId: "inbox-worker",
      leaseToken: leasedInbox.leaseToken,
      expiresAt: now.addingTimeInterval(7 * 86_400),
      at: now.addingTimeInterval(2)
    )
    let unblocked = try await fixture.store.claimIngestionReconciliationRequests(
      environment: "dev",
      sourceGeneration: Fixture.generation,
      workerId: "reconciliation-worker",
      limit: 1,
      leaseUntil: now.addingTimeInterval(60),
      at: now.addingTimeInterval(2)
    )
    #expect(unblocked.map(\.repoDid) == [did])
  }

  @Test("sealed incidents stay open through a dead letter and resolve after durable reconciliation")
  func reconciliationClosesTheSealedRecoverySeam() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 500, at: now)
    try fixture.sealReplay(at: 500, now: now)
    try fixture.seedIncident(sequence: 500, at: now)
    try fixture.seedEvent(
      sequence: 500,
      did: "did:plc:poison",
      kind: .commit,
      payload: "{}",
      attemptCount: 9,
      at: now
    )

    #expect(try await fixture.worker().drainOnce(at: now) == 1)
    #expect(try fixture.incidentStatus() == "open")
    #expect(try fixture.appliedWatermark() == nil)

    let restorer = SuccessfulRestorer()
    #expect(try await fixture.worker(restorer: restorer).drainOnce(at: now.addingTimeInterval(1)) == 1)
    #expect(await restorer.restoredDids() == ["did:plc:poison"])
    #expect(try fixture.incidentStatus() == "resolved")
    #expect(try fixture.appliedWatermark() == 500)
    #expect(try fixture.reconciliationRequestStatus(sequence: 500) == "completed")
  }

  @Test("sync reconciliation records repository and applied watermarks")
  func syncUsesRepositoryReconciliation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    let did = "did:plc:sync"
    try fixture.seedCheckpoint(lastStagedSequence: 700, at: now)
    try fixture.seedEvent(
      sequence: 700,
      did: did,
      kind: .sync,
      repoRev: "3ksync",
      payload: Self.syncPayload(700, did: did),
      at: now
    )
    let restorer = SuccessfulRestorer()

    #expect(try await fixture.worker(restorer: restorer).drainOnce(at: now) == 1)
    #expect(await restorer.restoredDids() == [did])
    #expect(try fixture.reconciledRevision() == "3ksync")
    #expect(try fixture.appliedWatermark() == 700)
  }

  @Test("a timed-out sync retries without pinning an unrelated repository")
  func timedOutSyncReleasesWorkerCapacity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    let stalledDid = "did:plc:stalled"
    let unrelatedDid = "did:plc:unrelated"
    try fixture.seedCheckpoint(lastStagedSequence: 801, at: now)
    try fixture.seedEvent(
      sequence: 800,
      did: stalledDid,
      kind: .sync,
      repoRev: "3kstalled",
      payload: Self.syncPayload(800, did: stalledDid),
      at: now
    )
    try fixture.seedEvent(
      sequence: 801,
      did: unrelatedDid,
      payload: Self.identityPayload(801, did: unrelatedDid),
      at: now
    )
    let restorer = BlockingRestorer()

    #expect(
      try await fixture.worker(
        restorer: restorer,
        projectionTimeoutSeconds: 0.05
      ).drainOnce(at: now) == 2
    )

    #expect(await restorer.cancellationObserved)
    #expect(try fixture.status(sequence: 800) == "retry")
    #expect(try fixture.attemptCount(sequence: 800) == 1)
    #expect(try fixture.status(sequence: 801) == "applied")
  }

  @Test("cancelling the long-lived worker cancels live and reconciliation children")
  func longLivedWorkerPropagatesCancellationToBothLoops() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    let did = "did:plc:cancelled"
    try fixture.seedCheckpoint(lastStagedSequence: 810, at: now)
    try fixture.seedEvent(
      sequence: 810,
      did: did,
      kind: .sync,
      repoRev: "3kcancelled",
      payload: Self.syncPayload(810, did: did),
      at: now
    )
    try fixture.seedReconciliationRequest(
      sequence: 809,
      did: "did:plc:cancelled-reconciliation",
      at: now
    )
    let restorer = BlockingRestorer()
    let run = Task { await fixture.worker(restorer: restorer).runForever() }

    #expect(await Self.eventually { await restorer.startedCount == 2 })
    run.cancel()
    await run.value

    #expect(await restorer.cancellationCount == 2)
    #expect(try fixture.status(sequence: 810) == "leased")
    #expect(try fixture.reconciliationRequestStatus(sequence: 809) == "leased")
  }

  @Test("only parent task cancellation terminates a long-lived loop")
  func cancellationTerminationPolicy() {
    #expect(
      !JetstreamInboxProjectionWorker.shouldStopLoopAfterCancellation(
        parentTaskIsCancelled: false
      )
    )
    #expect(
      JetstreamInboxProjectionWorker.shouldStopLoopAfterCancellation(
        parentTaskIsCancelled: true
      )
    )
  }

  @Test("delayed live refill receives a fresh lease expiry")
  func delayedLiveRefillUsesFreshClaimTime() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.installLeaseExpiryAudit()
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 821, at: now)
    try fixture.seedEvent(
      sequence: 820,
      did: "did:plc:delayed-live",
      kind: .sync,
      repoRev: "3kdelayed",
      payload: Self.syncPayload(820, did: "did:plc:delayed-live"),
      at: now
    )
    try fixture.seedEvent(
      sequence: 821,
      did: "did:plc:refilled-live",
      payload: Self.identityPayload(821, did: "did:plc:refilled-live"),
      at: now
    )
    let restorer = GatedRestorer()
    let worker = fixture.worker(
      restorer: restorer,
      projectionTimeoutSeconds: 5,
      maxConcurrency: 1
    )
    let drain = Task { try await worker.drainLiveUntilIdle(at: now) }

    #expect(await Self.eventually { await restorer.startedCount == 1 })
    try await Task.sleep(for: .milliseconds(1_500))
    let refillNotBefore = Date()
    await restorer.releaseAll()

    #expect(try await drain.value == 2)
    let auditedExpiry = try fixture.inboxLeaseExpiry(sequence: 821)
    let expiry = try #require(auditedExpiry)
    #expect(expiry.timeIntervalSince(refillNotBefore) >= 58.75)
  }

  @Test("delayed reconciliation refill receives a fresh lease expiry")
  func delayedReconciliationRefillUsesFreshClaimTime() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.installLeaseExpiryAudit()
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 831, at: now)
    try fixture.seedEvent(
      sequence: 830,
      did: "did:plc:delayed-reconciliation",
      kind: .commit,
      payload: "{}",
      attemptCount: 9,
      at: now
    )
    try fixture.seedEvent(
      sequence: 831,
      did: "did:plc:refilled-reconciliation",
      kind: .commit,
      payload: "{}",
      attemptCount: 9,
      at: now
    )
    #expect(try await fixture.worker(maxConcurrency: 1).drainLiveUntilIdle(at: now) == 2)
    let restorer = GatedRestorer()
    let worker = fixture.worker(
      restorer: restorer,
      projectionTimeoutSeconds: 5,
      maxConcurrency: 1,
      reconciliationMaxConcurrency: 1
    )
    let drain = Task {
      try await worker.drainReconciliationsUntilIdle(at: now.addingTimeInterval(1))
    }

    #expect(await Self.eventually { await restorer.startedCount == 1 })
    try await Task.sleep(for: .milliseconds(1_500))
    let refillNotBefore = Date()
    await restorer.releaseAll()

    #expect(try await drain.value == 2)
    let auditedExpiry = try fixture.reconciliationLeaseExpiry(sequence: 831)
    let expiry = try #require(auditedExpiry)
    #expect(expiry.timeIntervalSince(refillNotBefore) >= 58.75)
  }

  @Test("rolling live drain refills capacity before a stalled tail finishes")
  func rollingDrainRefillsBeforeStalledTail() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 802, at: now)
    try fixture.seedEvent(
      sequence: 800,
      did: "did:plc:stalled",
      kind: .sync,
      repoRev: "3kstalled",
      payload: Self.syncPayload(800, did: "did:plc:stalled"),
      at: now
    )
    for sequence in Int64(801)...802 {
      let did = "did:plc:live-\(sequence)"
      try fixture.seedEvent(
        sequence: sequence,
        did: did,
        payload: Self.identityPayload(sequence, did: did),
        at: now
      )
    }
    let restorer = GatedRestorer()
    let worker = fixture.worker(restorer: restorer, projectionTimeoutSeconds: 5)
    let drain = Task { try await worker.drainOnce(at: now) }

    #expect(await Self.eventually { await restorer.startedCount == 1 })
    #expect(await Self.eventually { (try? fixture.status(sequence: 802)) == "applied" })
    #expect(try fixture.status(sequence: 800) == "leased")

    await restorer.releaseAll()
    #expect(try await drain.value == 3)
    #expect(try fixture.status(sequence: 800) == "applied")
    #expect(try fixture.appliedWatermark() == 802)
  }

  @Test("rolling live drain claims only bounded refill chunks")
  func rollingDrainUsesChunkedClaims() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 830, at: now)
    try fixture.seedEvent(
      sequence: 820,
      did: "did:plc:chunked-stall",
      kind: .sync,
      repoRev: "3kchunked",
      payload: Self.syncPayload(820, did: "did:plc:chunked-stall"),
      at: now
    )
    for sequence in Int64(821)...830 {
      let did = "did:plc:chunked-\(sequence)"
      try fixture.seedEvent(
        sequence: sequence,
        did: did,
        payload: Self.identityPayload(sequence, did: did),
        at: now
      )
    }
    let restorer = GatedRestorer()
    let recorder = ClaimRecorder()
    let worker = fixture.worker(restorer: restorer, projectionTimeoutSeconds: 5, maxConcurrency: 8)
    let drain = Task {
      try await worker.drainLiveUntilIdle(at: now) { limit, claimed in
        await recorder.record(limit: limit, claimed: claimed)
      }
    }

    #expect(await Self.eventually { (try? fixture.status(sequence: 830)) == "applied" })
    let positiveClaims = await recorder.positiveClaims
    #expect(
      positiveClaims == [
        ClaimRecord(limit: 8, claimed: 8),
        ClaimRecord(limit: 2, claimed: 2),
        ClaimRecord(limit: 2, claimed: 1),
      ]
    )
    #expect(try fixture.status(sequence: 820) == "leased")

    await restorer.releaseAll()
    #expect(try await drain.value == 11)
    #expect(try fixture.appliedWatermark() == 830)
  }

  @Test("blocked reconciliation does not consume live projection capacity")
  func reconciliationRunsIndependentlyFromLiveProjection() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 903, at: now)
    try fixture.seedEvent(
      sequence: 900,
      did: "did:plc:recovery",
      kind: .commit,
      payload: "{}",
      attemptCount: 9,
      at: now
    )
    #expect(try await fixture.worker().drainOnce(at: now) == 1)
    for sequence in Int64(901)...903 {
      let did = "did:plc:live-\(sequence)"
      try fixture.seedEvent(
        sequence: sequence,
        did: did,
        payload: Self.identityPayload(sequence, did: did),
        at: now
      )
    }

    let restorer = GatedRestorer()
    let drain = Task {
      try await fixture.worker(
        restorer: restorer,
        reconciliationMaxConcurrency: 1
      ).drainOnce(at: now.addingTimeInterval(1))
    }

    #expect(await Self.eventually { await restorer.startedCount == 1 })
    #expect(await Self.eventually { (try? fixture.status(sequence: 903)) == "applied" })
    #expect(try fixture.reconciliationRequestStatus(sequence: 900) == "leased")

    await restorer.releaseAll()
    #expect(try await drain.value == 4)
    #expect(try fixture.reconciliationRequestStatus(sequence: 900) == "completed")
    #expect(try fixture.appliedWatermark() == 903)
  }

  @Test("reconciliation uses its independent bounded concurrency")
  func reconciliationConcurrencyIsBounded() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Date()
    try fixture.seedCheckpoint(lastStagedSequence: 3, at: now)
    for sequence in Int64(1)...3 {
      let did = "did:plc:recovery-\(sequence)"
      try fixture.seedEvent(
        sequence: sequence,
        did: did,
        kind: .commit,
        payload: "{}",
        attemptCount: 9,
        at: now
      )
    }
    #expect(
      try await fixture.worker(maxConcurrency: 3).drainOnce(at: now) == 3
    )

    let restorer = GatedRestorer()
    let drain = Task {
      try await fixture.worker(
        restorer: restorer,
        maxConcurrency: 3,
        reconciliationMaxConcurrency: 2
      ).drainOnce(at: now.addingTimeInterval(1))
    }

    #expect(await Self.eventually { await restorer.startedCount == 2 })
    #expect(await restorer.peakConcurrency == 2)
    #expect(await restorer.startedCount == 2)

    await restorer.releaseAll()
    #expect(try await drain.value == 3)
    #expect(await restorer.startedCount == 3)
    #expect(await restorer.peakConcurrency == 2)
    for sequence in Int64(1)...3 {
      #expect(try fixture.reconciliationRequestStatus(sequence: sequence) == "completed")
    }
  }

  @Test("retry backoff is bounded and jittered")
  func boundedRetryBackoff() {
    #expect(JetstreamInboxProjectionWorker.retryDelaySeconds(attempt: 1, jitterUnit: 0) == 0.25)
    #expect(JetstreamInboxProjectionWorker.retryDelaySeconds(attempt: 1, jitterUnit: 1) == 0.3125)
    #expect(JetstreamInboxProjectionWorker.retryDelaySeconds(attempt: 10, jitterUnit: 1) == 30)
  }

  private static func identityPayload(_ sequence: Int64, did: String) -> String {
    """
    {"did":"\(did)","cursor":\(sequence),"time_us":1700000000000000,"kind":"identity",\
    "identity":{"did":"\(did)","handle":"example.test","seq":1,"time":"2026-08-15T12:00:00Z"}}
    """
  }

  private static func commitPayload(sequence: Int64, did: String) -> String {
    """
    {"did":"\(did)","cursor":\(sequence),"time_us":1700000000000000,"kind":"commit",\
    "commit":{"operation":"create","collection":"site.standard.entry","rkey":"article",\
    "rev":"3kcreate","cid":"bafycreate","record":{"$type":"site.standard.entry",\
    "title":"Durable article","createdAt":"2026-08-15T12:00:00Z"}}}
    """
  }

  private static func accountPayload(_ sequence: Int64, did: String) -> String {
    """
    {"did":"\(did)","cursor":\(sequence),"time_us":1700000000000000,"kind":"account",\
    "account":{"did":"\(did)","active":false,"status":"deleted","seq":2,\
    "time":"2026-08-15T12:00:01Z"}}
    """
  }

  private static func syncPayload(_ sequence: Int64, did: String) -> String {
    """
    {"did":"\(did)","cursor":\(sequence),"time_us":1700000000000000,"kind":"sync",\
    "sync":{"did":"\(did)","rev":"3ksync","seq":3,"time":"2026-08-15T12:00:02Z"}}
    """
  }

  private static func eventually(
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    for _ in 0..<100 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private actor SuccessfulRestorer: TapRepositoryRestorer {
  private var dids: [String] = []

  func restoreCurrentRepository(repoDid: String) async throws -> PDSReconciliationReport {
    dids.append(repoDid)
    return PDSReconciliationReport(
      authorScope: PDSAuthorScopeEvidence(
        requestedAuthorDids: [repoDid],
        acceptedAuthorDids: [repoDid],
        issues: []
      ),
      limits: PDSReconciliationLimitsEvidence(
        maximumAuthors: 1,
        recordCapPerAuthor: 100,
        maxConcurrency: 1,
        rateLimitPerSecond: 10,
        maxRateLimitRetries: 3
      ),
      authors: [
        PDSAuthorReconciliationResult(
          authorDid: repoDid,
          pdsBase: "https://pds.example",
          collections: [],
          issues: []
        )
      ],
      unsupportedCollections: [],
      historicalDeletesProvable: false
    )
  }

  func restoredDids() -> [String] { dids }
}

private actor BlockingRestorer: TapRepositoryRestorer {
  private(set) var startedCount = 0
  private(set) var cancellationCount = 0

  var cancellationObserved: Bool { cancellationCount > 0 }

  func restoreCurrentRepository(repoDid: String) async throws -> PDSReconciliationReport {
    _ = repoDid
    startedCount += 1
    do {
      try await Task.sleep(for: .seconds(60))
      throw TapRepositoryRestorationError.unavailable
    } catch {
      cancellationCount += 1
      throw error
    }
  }
}

private actor GatedRestorer: TapRepositoryRestorer {
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var cancelledWaiters: Set<UUID> = []
  private var released = false
  private var active = 0
  private(set) var startedCount = 0
  private(set) var peakConcurrency = 0

  func restoreCurrentRepository(repoDid: String) async throws -> PDSReconciliationReport {
    startedCount += 1
    active += 1
    peakConcurrency = max(peakConcurrency, active)
    if !released {
      let waiterId = UUID()
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          registerWaiter(id: waiterId, continuation: continuation)
        }
      } onCancel: {
        Task { await self.cancelWaiter(id: waiterId) }
      }
    }
    active -= 1
    try Task.checkCancellation()
    return completeReconciliationReport(repoDid: repoDid)
  }

  func releaseAll() {
    released = true
    let pending = Array(waiters.values)
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }

  private func registerWaiter(id: UUID, continuation: CheckedContinuation<Void, Never>) {
    if released || cancelledWaiters.remove(id) != nil {
      continuation.resume()
    } else {
      waiters[id] = continuation
    }
  }

  private func cancelWaiter(id: UUID) {
    if let continuation = waiters.removeValue(forKey: id) {
      continuation.resume()
    } else {
      cancelledWaiters.insert(id)
    }
  }
}

private struct ClaimRecord: Sendable, Equatable {
  let limit: Int
  let claimed: Int
}

private actor ClaimRecorder {
  private var records: [ClaimRecord] = []

  var positiveClaims: [ClaimRecord] { records.filter { $0.claimed > 0 } }

  func record(limit: Int, claimed: Int) {
    records.append(ClaimRecord(limit: limit, claimed: claimed))
  }
}

private func completeReconciliationReport(repoDid: String) -> PDSReconciliationReport {
  PDSReconciliationReport(
    authorScope: PDSAuthorScopeEvidence(
      requestedAuthorDids: [repoDid],
      acceptedAuthorDids: [repoDid],
      issues: []
    ),
    limits: PDSReconciliationLimitsEvidence(
      maximumAuthors: 1,
      recordCapPerAuthor: 100,
      maxConcurrency: 1,
      rateLimitPerSecond: 10,
      maxRateLimitRetries: 3
    ),
    authors: [
      PDSAuthorReconciliationResult(
        authorDid: repoDid,
        pdsBase: "https://pds.example",
        collections: [],
        issues: []
      )
    ],
    unsupportedCollections: [],
    historicalDeletesProvable: false
  )
}

private struct Fixture {
  static let generation = "jetstream-v2-us-west-v1"

  let path: String
  let store: SQLiteThinAppViewStore
  let database: DatabaseQueue

  init() throws {
    path = FileManager.default.temporaryDirectory
      .appendingPathComponent("jetstream-inbox-\(UUID().uuidString).sqlite")
      .path
    store = try SQLiteThinAppViewStore(path: path, logger: Logger(label: "inbox.store.test"))
    database = try DatabaseQueue(path: path)
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: "\(path)-shm")
    try? FileManager.default.removeItem(atPath: "\(path)-wal")
  }

  func worker(
    restorer: (any TapRepositoryRestorer)? = nil,
    projectionTimeoutSeconds: TimeInterval = 120,
    maxConcurrency: Int = 2,
    reconciliationMaxConcurrency: Int = 2
  ) -> JetstreamInboxProjectionWorker {
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let logger = Logger(label: "inbox.worker.test")
    return JetstreamInboxProjectionWorker(
      store: store,
      indexers: (0..<maxConcurrency).map {
        _ in ThinAppViewIndexer(store: store, config: config, logger: logger)
      },
      repositoryRestorer: restorer,
      environment: "dev",
      sourceGeneration: Self.generation,
      workerId: "test-worker",
      maxConcurrency: maxConcurrency,
      leaseSeconds: 60,
      pollMilliseconds: 25,
      appliedRetentionSeconds: config.ingestionInboxAppliedRetentionSeconds,
      deadLetterRetentionSeconds: config.ingestionInboxDeadLetterRetentionSeconds,
      projectionTimeoutSeconds: projectionTimeoutSeconds,
      reconciliationMaxConcurrency: reconciliationMaxConcurrency,
      logger: logger
    )
  }

  func seedCheckpoint(lastStagedSequence: Int64, at: Date) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_jetstream_checkpoints
            (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
             cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at,
             replay_state, updated_at)
          VALUES (?, ?, ?, ?, ?, 'jetstream_v2_seq', ?, ?, ?, 'live', ?)
          """,
        arguments: [
          "dev",
          Self.generation,
          "jetstream.us-west.bsky.network",
          "network.bsky.jetstream.subscribeEvents",
          "fixture-filter",
          lastStagedSequence,
          Self.iso(at),
          Self.iso(at),
          Self.iso(at),
        ]
      )
    }
  }

  func seedEvent(
    sequence: Int64,
    did: String,
    kind: AppViewIngestionEventKind = .identity,
    collection: String? = nil,
    operation: String? = nil,
    repoRev: String? = nil,
    recordKey: String? = nil,
    recordCID: String? = nil,
    payload: String,
    attemptCount: Int = 0,
    at: Date
  ) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_inbox
            (environment, source_generation, seq, source_host, cursor_kind, event_kind,
             repo_did, collection, operation, repo_rev, record_key, record_cid, payload,
             event_time, status, attempt_count, next_attempt_at, staged_at, expires_at, updated_at)
          VALUES (?, ?, ?, ?, 'jetstream_v2_seq', ?, ?, ?, ?, ?, ?, ?, ?, ?,
                  'pending', ?, ?, ?, ?, ?)
          """,
        arguments: [
          "dev",
          Self.generation,
          sequence,
          "jetstream.us-west.bsky.network",
          kind.rawValue,
          did,
          collection,
          operation,
          repoRev,
          recordKey,
          recordCID,
          payload,
          Self.iso(at),
          attemptCount,
          Self.iso(at),
          Self.iso(at),
          Self.iso(at.addingTimeInterval(30 * 86_400)),
          Self.iso(at),
        ]
      )
    }
  }

  func sealReplay(at sequence: Int64, now: Date) throws {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE appview_jetstream_checkpoints
          SET replay_state = 'live', replay_sealed_seq = ?, updated_at = ?
          WHERE environment = 'dev' AND source_generation = ?
          """,
        arguments: [sequence, Self.iso(now), Self.generation]
      )
    }
  }

  func seedIncident(sequence: Int64, at: Date) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_incidents
            (environment, id, source_generation, source, cursor_kind, start_cursor, end_cursor,
             category, status, occurrence_count, first_detected_at, last_detected_at,
             replay_state, replay_sealed_seq, updated_at)
          VALUES ('dev', 'incident', ?, 'jetstream-v2', 'jetstream_v2_seq', ?, ?,
                  'transport_error', 'open', 1, ?, ?, 'recovering', ?, ?)
          """,
        arguments: [
          Self.generation, sequence, sequence, Self.iso(at), Self.iso(at), sequence, Self.iso(at),
        ]
      )
    }
  }

  func seedReconciliationRequest(sequence: Int64, did: String, at: Date) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_reconciliation_requests
            (environment, id, source_generation, repo_did, reason, trigger_seq, status,
             attempt_count, next_attempt_at, created_at, updated_at)
          VALUES ('dev', ?, ?, ?, 'test', ?, 'pending', 0, ?, ?, ?)
          """,
        arguments: [
          "\(Self.generation):\(sequence):\(did)", Self.generation, did, sequence,
          Self.iso(at), Self.iso(at), Self.iso(at),
        ]
      )
    }
  }

  func appliedWatermark() throws -> Int64? {
    try database.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT last_applied_seq FROM appview_jetstream_checkpoints WHERE environment = 'dev'"
      )
    }
  }

  func installWatermarkUpdateCounter() throws {
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE watermark_update_audit (sequence INTEGER NOT NULL);
          CREATE TRIGGER count_watermark_updates
          AFTER UPDATE OF last_applied_seq ON appview_jetstream_checkpoints
          WHEN NEW.last_applied_seq IS NOT OLD.last_applied_seq
          BEGIN
            INSERT INTO watermark_update_audit (sequence) VALUES (NEW.last_applied_seq);
          END;
          """
      )
    }
  }

  func watermarkUpdateCount() throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watermark_update_audit") ?? 0
    }
  }

  func installLeaseExpiryAudit() throws {
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE lease_expiry_audit (
            claim_kind TEXT NOT NULL,
            claim_key INTEGER NOT NULL,
            lease_expires_at TEXT NOT NULL
          );
          CREATE TRIGGER audit_inbox_lease_expiry
          AFTER UPDATE OF status ON appview_ingestion_inbox
          WHEN NEW.status = 'leased'
          BEGIN
            INSERT INTO lease_expiry_audit (claim_kind, claim_key, lease_expires_at)
            VALUES ('inbox', NEW.seq, NEW.lease_expires_at);
          END;
          CREATE TRIGGER audit_reconciliation_lease_expiry
          AFTER UPDATE OF status ON appview_ingestion_reconciliation_requests
          WHEN NEW.status = 'leased'
          BEGIN
            INSERT INTO lease_expiry_audit (claim_kind, claim_key, lease_expires_at)
            VALUES ('reconciliation', NEW.trigger_seq, NEW.lease_expires_at);
          END;
          """
      )
    }
  }

  func inboxLeaseExpiry(sequence: Int64) throws -> Date? {
    try leaseExpiry(kind: "inbox", key: sequence)
  }

  func reconciliationLeaseExpiry(sequence: Int64) throws -> Date? {
    try leaseExpiry(kind: "reconciliation", key: sequence)
  }

  func reconciledRevision() throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT last_reconciled_repo_rev FROM appview_jetstream_checkpoints WHERE environment = 'dev'"
      )
    }
  }

  func status(sequence: Int64) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT status FROM appview_ingestion_inbox WHERE seq = ?",
        arguments: [sequence]
      )
    }
  }

  func attemptCount(sequence: Int64) throws -> Int? {
    try database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT attempt_count FROM appview_ingestion_inbox WHERE seq = ?",
        arguments: [sequence]
      )
    }
  }

  func reconciliationRequestCount(sequence: Int64) throws -> Int {
    try database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM appview_ingestion_reconciliation_requests WHERE trigger_seq = ?",
        arguments: [sequence]
      ) ?? 0
    }
  }

  func reconciliationRequestStatus(sequence: Int64) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT status FROM appview_ingestion_reconciliation_requests WHERE trigger_seq = ?",
        arguments: [sequence]
      )
    }
  }

  func incidentStatus() throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT status FROM appview_ingestion_incidents WHERE id = 'incident'"
      )
    }
  }

  private func leaseExpiry(kind: String, key: Int64) throws -> Date? {
    let raw = try database.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT lease_expires_at
          FROM lease_expiry_audit
          WHERE claim_kind = ? AND claim_key = ?
          ORDER BY rowid DESC
          LIMIT 1
          """,
        arguments: [kind, key]
      )
    }
    return raw.flatMap { ISO8601DateFormatter().date(from: $0) }
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
