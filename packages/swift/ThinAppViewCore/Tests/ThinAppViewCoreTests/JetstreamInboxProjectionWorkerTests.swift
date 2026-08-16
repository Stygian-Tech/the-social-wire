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
    #expect(try fixture.appliedWatermark() == 100)
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

  @Test("worker applies ordered commits and account lifecycle events")
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

    #expect(try await worker.drainOnce(at: now) == 1)
    let uri = "at://\(did)/site.standard.entry/article"
    #expect(try await fixture.store.fetchContentIdentity(uri: uri) != nil)
    #expect(try await worker.drainOnce(at: now.addingTimeInterval(1)) == 1)
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

  func worker(restorer: (any TapRepositoryRestorer)? = nil) -> JetstreamInboxProjectionWorker {
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let logger = Logger(label: "inbox.worker.test")
    return JetstreamInboxProjectionWorker(
      store: store,
      indexers: (0..<2).map { _ in ThinAppViewIndexer(store: store, config: config, logger: logger) },
      repositoryRestorer: restorer,
      environment: "dev",
      sourceGeneration: Self.generation,
      workerId: "test-worker",
      maxConcurrency: 2,
      leaseSeconds: 60,
      pollMilliseconds: 25,
      appliedRetentionSeconds: config.ingestionInboxAppliedRetentionSeconds,
      deadLetterRetentionSeconds: config.ingestionInboxDeadLetterRetentionSeconds,
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

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
