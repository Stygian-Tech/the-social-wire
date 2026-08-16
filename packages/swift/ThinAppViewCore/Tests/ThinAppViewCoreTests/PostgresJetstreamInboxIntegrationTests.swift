import Foundation
import Logging
import PostgresNIO
import Testing

@testable import ThinAppViewCore

@Suite(
  "Postgres durable Jetstream V2 inbox",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil,
    "Set THIN_APPVIEW_TEST_DATABASE_URL to an explicitly disposable Postgres database."
  )
)
struct PostgresJetstreamInboxIntegrationTests {
  @Test("concurrent workers claim disjoint rows with SKIP LOCKED")
  func concurrentWorkersClaimDisjointRows() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 8, at: now)
      for sequence in Int64(1)...8 {
        try await fixture.seedInbox(
          sequence: sequence,
          repoDid: "did:plc:concurrent-\(sequence)",
          at: now
        )
      }

      let barrier = PostgresClaimBarrier()
      let firstClaim = Task {
        try await fixture.holdFirstClaimTransaction(
          sequences: Set(Int64(1)...Int64(4)),
          workerId: "worker-a",
          at: now,
          barrier: barrier
        )
      }
      await barrier.waitUntilLocked()

      let secondCompletion = PostgresClaimCompletion()
      let secondClaim = Task {
        do {
          let result = try await fixture.store.claimIngestionInbox(
            environment: fixture.environment,
            sourceGeneration: fixture.sourceGeneration,
            workerId: "worker-b",
            limit: 4,
            leaseUntil: now.addingTimeInterval(30),
            at: now
          )
          await secondCompletion.markComplete()
          return result
        } catch {
          await secondCompletion.markComplete()
          throw error
        }
      }
      let secondCompletedBeforeRelease = await Self.eventually {
        await secondCompletion.isComplete
      }
      await barrier.release()
      let second = try await secondClaim.value
      let first = try await firstClaim.value
      let firstSequences = Set(first)
      let secondSequences = Set(second.map(\.sequence))

      #expect(secondCompletedBeforeRelease)
      #expect(firstSequences.count == 4)
      #expect(secondSequences.count == 4)
      #expect(firstSequences.isDisjoint(with: secondSequences))
      #expect(firstSequences.union(secondSequences) == Set(Int64(1)...Int64(8)))
    }
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

  @Test("Postgres claims at most one FIFO event per repository")
  func claimsOneFIFOEventPerRepository() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 3, at: now)
      try await fixture.seedInbox(sequence: 1, repoDid: "did:plc:fifo", at: now)
      try await fixture.seedInbox(sequence: 2, repoDid: "did:plc:fifo", at: now)
      try await fixture.seedInbox(sequence: 3, repoDid: "did:plc:other", at: now)

      let first = try await fixture.claim(workerId: "fifo-worker", limit: 3, at: now)
      #expect(first.map(\.sequence) == [1, 3])
      guard let firstFIFO = first.first(where: { $0.sequence == 1 }) else {
        Issue.record("Expected the first FIFO row to be claimed")
        return
      }
      try await fixture.markApplied(firstFIFO, workerId: "fifo-worker", at: now)

      let second = try await fixture.claim(
        workerId: "fifo-worker",
        limit: 3,
        at: now.addingTimeInterval(1)
      )
      #expect(second.map(\.sequence) == [2])
    }
  }

  @Test("expired leases can be taken over and stale tokens stay fenced")
  func expiredLeaseTakeoverFencesStaleToken() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 10, at: now)
      try await fixture.seedInbox(
        sequence: 10,
        repoDid: "did:plc:takeover",
        status: "leased",
        leaseOwner: "old-worker",
        leaseToken: "old-token",
        leaseExpiresAt: now.addingTimeInterval(-1),
        at: now
      )

      let claimed = try await fixture.claim(workerId: "new-worker", limit: 1, at: now)
      #expect(claimed.map(\.sequence) == [10])
      let newLease = try #require(claimed.first)
      #expect(newLease.leaseToken != "old-token")

      await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
        try await fixture.store.markIngestionInboxApplied(
          environment: fixture.environment,
          sourceGeneration: fixture.sourceGeneration,
          sequence: 10,
          workerId: "old-worker",
          leaseToken: "old-token",
          expiresAt: now.addingTimeInterval(3_600),
          at: now
        )
      }
      try await fixture.store.renewIngestionInboxLease(
        environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration,
        sequence: 10,
        workerId: "new-worker",
        leaseToken: newLease.leaseToken,
        leaseUntil: now.addingTimeInterval(60),
        at: now
      )
      try await fixture.markApplied(newLease, workerId: "new-worker", at: now)
    }
  }

  @Test("watermark waits for the terminal prefix despite out-of-order completion")
  func watermarkAdvancesOnlyAcrossTerminalPrefix() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 30, at: now)
      for sequence in [Int64(10), 20, 30] {
        try await fixture.seedInbox(
          sequence: sequence,
          repoDid: "did:plc:watermark-\(sequence)",
          at: now
        )
      }
      let claimed = try await fixture.claim(workerId: "watermark-worker", limit: 3, at: now)
      let bySequence = Dictionary(uniqueKeysWithValues: claimed.map { ($0.sequence, $0) })

      try await fixture.markApplied(
        try #require(bySequence[30]),
        workerId: "watermark-worker",
        at: now
      )
      try await fixture.markApplied(
        try #require(bySequence[20]),
        workerId: "watermark-worker",
        at: now
      )
      try await fixture.store.advanceIngestionInboxAppliedWatermark(
        environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration,
        at: now
      )
      #expect(try await fixture.appliedWatermark() == nil)

      try await fixture.markApplied(
        try #require(bySequence[10]),
        workerId: "watermark-worker",
        at: now
      )
      try await fixture.store.advanceIngestionInboxAppliedWatermark(
        environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration,
        at: now.addingTimeInterval(1)
      )
      #expect(try await fixture.appliedWatermark() == 30)
    }
  }

  @Test("sixteen connections serve thirty-two logical claims and timely renewals")
  func sixteenConnectionPoolServesThirtyTwoLogicalWorkers() async throws {
    try await PostgresInboxFixture.withFixture(maximumConnections: 16) { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 32, at: now)
      for sequence in Int64(1)...32 {
        try await fixture.seedInbox(
          sequence: sequence,
          repoDid: "did:plc:stress-\(sequence)",
          at: now
        )
      }

      let claimed = try await withThrowingTaskGroup(
        of: [StressLease].self,
        returning: [StressLease].self
      ) { group in
        for worker in 0..<32 {
          group.addTask {
            let workerId = "stress-worker-\(worker)"
            let items = try await fixture.store.claimIngestionInbox(
              environment: fixture.environment,
              sourceGeneration: fixture.sourceGeneration,
              workerId: workerId,
              limit: 1,
              leaseUntil: now.addingTimeInterval(30),
              at: now
            )
            return items.map { StressLease(workerId: workerId, item: $0) }
          }
        }
        var result: [StressLease] = []
        for try await batch in group { result.append(contentsOf: batch) }
        return result
      }
      #expect(claimed.count == 32)
      #expect(Set(claimed.map(\.item.sequence)).count == 32)

      let renewalStartedAt = Date()
      try await withThrowingTaskGroup(of: Void.self) { group in
        for lease in claimed {
          group.addTask {
            try await fixture.store.renewIngestionInboxLease(
              environment: fixture.environment,
              sourceGeneration: fixture.sourceGeneration,
              sequence: lease.item.sequence,
              workerId: lease.workerId,
              leaseToken: lease.item.leaseToken,
              leaseUntil: now.addingTimeInterval(90),
              at: Date()
            )
          }
        }
        try await group.waitForAll()
      }
      // Stay inside the production 20-second renewal interval without making hosted-runner
      // scheduling noise a flaky sub-second performance gate.
      #expect(Date().timeIntervalSince(renewalStartedAt) < 15)
    }
  }
}

private final class PostgresInboxFixture: @unchecked Sendable {
  static let testURL = ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"]

  let environment: String
  let sourceGeneration: String
  let store: PostgresThinAppViewStore

  private let pool: PostgresClient
  private let logger: Logger
  private let runTask: Task<Void, Never>

  private init(url: String, maximumConnections: Int) async throws {
    environment = "swift-integration-\(UUID().uuidString.lowercased())"
    sourceGeneration = "jetstream-integration-\(UUID().uuidString.lowercased())"
    logger = Logger(label: "postgres-inbox.integration")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = maximumConnections
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    self.pool = pool
    store = PostgresThinAppViewStore(pool: pool, logger: logger)
    runTask = Task { await pool.run() }
    await Task.yield()
    try await store.ping()
    try await installMinimalSchema()
  }

  static func withFixture(
    maximumConnections: Int = 4,
    _ body: @escaping @Sendable (PostgresInboxFixture) async throws -> Void
  ) async throws {
    guard let testURL else { return }
    let fixture = try await PostgresInboxFixture(
      url: testURL,
      maximumConnections: maximumConnections
    )
    do {
      try await body(fixture)
    } catch {
      await fixture.shutdown()
      throw error
    }
    await fixture.shutdown()
  }

  func claim(
    workerId: String,
    limit: Int,
    at now: Date
  ) async throws -> [AppViewIngestionInboxItem] {
    try await store.claimIngestionInbox(
      environment: environment,
      sourceGeneration: sourceGeneration,
      workerId: workerId,
      limit: limit,
      leaseUntil: now.addingTimeInterval(30),
      at: now
    )
  }

  func markApplied(
    _ item: AppViewIngestionInboxItem,
    workerId: String,
    at now: Date
  ) async throws {
    try await store.markIngestionInboxApplied(
      environment: environment,
      sourceGeneration: sourceGeneration,
      sequence: item.sequence,
      workerId: workerId,
      leaseToken: item.leaseToken,
      expiresAt: now.addingTimeInterval(3_600),
      at: now
    )
  }

  func seedCheckpoint(lastStagedSequence: Int64, at now: Date) async throws {
    try await execute(
      """
      INSERT INTO appview_jetstream_checkpoints
        (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
         cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at, replay_state,
         updated_at)
      VALUES
        (\(environment), \(sourceGeneration), 'integration.jetstream.invalid',
         'network.bsky.jetstream.subscribeEvents', 'integration-filter',
         'jetstream_v2_seq', \(lastStagedSequence), \(now), \(now), 'live', \(now))
      """
    )
  }

  func seedInbox(
    sequence: Int64,
    repoDid: String,
    status: String = "pending",
    leaseOwner: String? = nil,
    leaseToken: String? = nil,
    leaseExpiresAt: Date? = nil,
    at now: Date
  ) async throws {
    let payload = "{}"
    try await execute(
      """
      INSERT INTO appview_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         payload, event_time, status, attempt_count, next_attempt_at, lease_owner, lease_token,
         lease_expires_at, staged_at, updated_at)
      VALUES
        (\(environment), \(sourceGeneration), \(sequence), 'integration.jetstream.invalid',
         'jetstream_v2_seq', 'identity', \(repoDid), \(payload)::jsonb, \(now), \(status), 0,
         \(now), \(leaseOwner), \(leaseToken), \(leaseExpiresAt), \(now), \(now))
      """
    )
  }

  func appliedWatermark() async throws -> Int64? {
    let rows = try await pool.query(
      """
      SELECT last_applied_seq
      FROM appview_jetstream_checkpoints
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode((Int64?).self)
    }
    return nil
  }

  func holdFirstClaimTransaction(
    sequences: Set<Int64>,
    workerId: String,
    at now: Date,
    barrier: PostgresClaimBarrier
  ) async throws -> [Int64] {
    let leaseToken = UUID().uuidString.lowercased()
    let sequenceList = sequences.sorted().map(String.init).joined(separator: ",")
    return try await pool.withTransaction(logger: logger) { connection in
      // sequenceList is derived solely from bounded Int64 test inputs. All external values
      // remain parameter-bound by PostgresQuery string interpolation.
      let lockQuery: PostgresQuery = """
        SELECT seq
        FROM appview_ingestion_inbox
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND seq IN (\(unescaped: sequenceList))
        ORDER BY seq
        FOR UPDATE
        """
      let rows = try await connection.query(
        lockQuery,
        logger: logger
      )
      var locked: [Int64] = []
      for try await row in rows { locked.append(try row.decode(Int64.self)) }
      let updateQuery: PostgresQuery = """
        UPDATE appview_ingestion_inbox
        SET status = 'leased', lease_owner = \(workerId), lease_token = \(leaseToken),
            lease_expires_at = \(now.addingTimeInterval(30)), updated_at = \(now)
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND seq IN (\(unescaped: sequenceList))
        """
      let updated = try await connection.query(
        updateQuery,
        logger: logger
      )
      for try await _ in updated {}
      await barrier.markLockedAndWaitForRelease()
      return locked
    }
  }

  private func installMinimalSchema() async throws {
    let statements: [PostgresQuery] = [
      """
      CREATE TABLE IF NOT EXISTS appview_jetstream_checkpoints (
        environment TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        source_host TEXT NOT NULL,
        stream_nsid TEXT NOT NULL,
        filter_fingerprint TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        last_staged_seq BIGINT,
        last_staged_event_at TIMESTAMPTZ,
        last_staged_at TIMESTAMPTZ,
        last_applied_seq BIGINT,
        last_applied_event_at TIMESTAMPTZ,
        last_applied_at TIMESTAMPTZ,
        replay_state TEXT NOT NULL DEFAULT 'idle',
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (environment, source_generation)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_ingestion_inbox (
        environment TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        seq BIGINT NOT NULL,
        source_host TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        event_kind TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        collection TEXT,
        operation TEXT,
        repo_rev TEXT,
        record_key TEXT,
        record_cid TEXT,
        payload JSONB NOT NULL,
        event_time TIMESTAMPTZ NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        lease_owner TEXT,
        lease_token TEXT,
        lease_expires_at TIMESTAMPTZ,
        failure_category TEXT,
        failure_reason TEXT,
        staged_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        applied_at TIMESTAMPTZ,
        dead_lettered_at TIMESTAMPTZ,
        reconciled_at TIMESTAMPTZ,
        expires_at TIMESTAMPTZ,
        PRIMARY KEY (environment, source_generation, seq)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_ingestion_reconciliation_requests (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        PRIMARY KEY (environment, id)
      )
      """,
    ]
    for statement in statements { try await execute(statement) }
  }

  private func execute(_ query: PostgresQuery) async throws {
    let rows = try await pool.query(query, logger: logger)
    for try await _ in rows {}
  }

  private func shutdown() async {
    try? await execute(
      """
      DELETE FROM appview_ingestion_reconciliation_requests
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """
    )
    try? await execute(
      """
      DELETE FROM appview_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """
    )
    try? await execute(
      """
      DELETE FROM appview_jetstream_checkpoints
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """
    )
    runTask.cancel()
    await runTask.value
  }
}

private struct StressLease: Sendable {
  let workerId: String
  let item: AppViewIngestionInboxItem
}

private actor PostgresClaimBarrier {
  private var locked = false
  private var released = false
  private var lockWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilLocked() async {
    if locked { return }
    await withCheckedContinuation { lockWaiters.append($0) }
  }

  func markLockedAndWaitForRelease() async {
    locked = true
    let pendingLockWaiters = lockWaiters
    lockWaiters.removeAll()
    for waiter in pendingLockWaiters { waiter.resume() }
    if released { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func release() {
    released = true
    let pendingReleaseWaiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in pendingReleaseWaiters { waiter.resume() }
  }
}

private actor PostgresClaimCompletion {
  private(set) var isComplete = false

  func markComplete() {
    isComplete = true
  }
}
