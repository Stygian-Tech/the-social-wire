import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWireInboxProcessor: Sendable {
  private struct InboxEvent: Sendable {
    let environment: String
    let sourceGeneration: String
    let sequence: Int64
    let sourceHost: String
    let cursorKind: String
    let eventKind: String
    let repoDID: String
    let collection: String?
    let operation: String?
    let recordKey: String?
    let payloadJSON: String
    let eventTime: Date
    let leaseToken: String
    let attemptCount: Int

    var sourceURI: String? {
      guard let collection, let recordKey else { return nil }
      return "at://\(repoDID)/\(collection)/\(recordKey)"
    }
  }

  private enum ApplyError: Error {
    case unresolvedReference
    case unresolvedPublication
    case malformed
  }

  let pool: PostgresClient
  let logger: Logger
  let actorHasher: WireActorHasher
  let publicationResolver: any WirePublicationResolving
  let linkMetadataStore: any WireLinkMetadataStoring
  let mentionStore: any WireTalkedAccountMentionStoring
  let batchSize: Int
  let maximumConcurrentEvents: Int
  let sourceScope: WireInboxSourceScope?

  init(
    pool: PostgresClient,
    logger: Logger,
    actorSecret: String,
    publicationResolver: (any WirePublicationResolving)? = nil,
    linkMetadataStore: (any WireLinkMetadataStoring)? = nil,
    mentionStore: (any WireTalkedAccountMentionStoring)? = nil,
    batchSize: Int = 1_000,
    maximumConcurrentEvents: Int = 16,
    sourceScope: WireInboxSourceScope? = nil
  ) throws {
    self.pool = pool
    self.logger = logger
    self.actorHasher = try WireActorHasher(secret: Data(actorSecret.utf8))
    self.publicationResolver =
      publicationResolver
      ?? WirePublicationResolver(
        store: PostgresWirePublicationMetadataStore(pool: pool, logger: logger),
        queryClient: nil
      )
    self.linkMetadataStore =
      linkMetadataStore ?? PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    self.mentionStore =
      mentionStore ?? PostgresWireTalkedAccountMentionStore(pool: pool, logger: logger)
    self.batchSize = max(1, min(batchSize, 5_000))
    self.maximumConcurrentEvents = max(1, min(maximumConcurrentEvents, 64))
    self.sourceScope = sourceScope
  }

  func process(asOf: Date) async throws -> Int {
    try await processWithMetrics(asOf: asOf).attemptedEventCount
  }

  func processWithMetrics(asOf: Date) async throws -> WireInboxDrainBatchMetrics {
    let fastPathCount = try await acknowledgeUnresolvedPassiveReferences(
      asOf: asOf,
      limit: batchSize
    )
    let passiveDeleteEvents = try await claimScopedPassiveDeletes(asOf: asOf)
    let events = passiveDeleteEvents + (try await claim(asOf: asOf))
    var iterator = events.makeIterator()
    var appliedEventCount = fastPathCount
    try await withThrowingTaskGroup(of: Bool.self) { tasks in
      for _ in 0..<min(maximumConcurrentEvents, events.count) {
        guard let event = iterator.next() else { break }
        tasks.addTask { try await process(event, asOf: asOf) }
      }
      while let applied = try await tasks.next() {
        if applied { appliedEventCount += 1 }
        guard let event = iterator.next() else { continue }
        tasks.addTask { try await process(event, asOf: asOf) }
      }
    }
    return WireInboxDrainBatchMetrics(
      attemptedEventCount: fastPathCount + events.count,
      appliedEventCount: appliedEventCount
    )
  }

  static func boundedClaimLimit(batchSize: Int, maximumConcurrentEvents: Int) -> Int {
    let boundedBatchSize = max(1, min(batchSize, 5_000))
    let boundedConcurrency = max(1, min(maximumConcurrentEvents, 64))
    return min(boundedBatchSize, boundedConcurrency)
  }

  static func retriesUnresolvedReference(collection: String?) -> Bool {
    collection != "app.bsky.feed.like" && collection != "app.bsky.feed.repost"
  }

  static func referenceSubjectURI(record: [String: Any], collection: String?) -> String? {
    if collection == "site.standard.graph.recommend",
      let document = record["document"] as? String
    {
      return document
    }
    let subject = record["subject"]
    if let string = subject as? String { return string }
    return (subject as? [String: Any])?["uri"] as? String
  }

  func acknowledgeUnresolvedPassiveReferences(asOf: Date, limit: Int) async throws -> Int {
    if let sourceScope {
      return try await acknowledgeScopedUnresolvedPassiveReferences(
        asOf: asOf, limit: limit, sourceScope: sourceScope)
    }
    let expiresAt = asOf.addingTimeInterval(300)
    let boundedLimit = max(1, min(limit, 5_000))
    return try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        WITH candidates AS (
          SELECT candidate.environment, candidate.source_generation, candidate.seq
          FROM wire_ingestion_inbox candidate
          WHERE candidate.status IN ('pending', 'retry')
            AND candidate.next_attempt_at <= \(asOf)
            AND candidate.event_kind = 'commit'
            AND candidate.collection IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
            AND candidate.operation IN ('create', 'update')
            AND NULLIF(BTRIM(COALESCE(
              candidate.payload #>> '{commit,record,subject,uri}',
              CASE
                WHEN jsonb_typeof(candidate.payload #> '{commit,record,subject}') = 'string'
                THEN candidate.payload #>> '{commit,record,subject}'
              END
            )), '') IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM wire_item_aliases alias
              WHERE alias.alias_key = COALESCE(
                candidate.payload #>> '{commit,record,subject,uri}',
                CASE
                  WHEN jsonb_typeof(candidate.payload #> '{commit,record,subject}') = 'string'
                  THEN candidate.payload #>> '{commit,record,subject}'
                END
              )
                AND alias.expires_at > \(asOf)
            )
            AND NOT EXISTS (
              SELECT 1 FROM wire_ingestion_inbox earlier
              WHERE earlier.environment = candidate.environment
                AND earlier.source_generation = candidate.source_generation
                AND earlier.repo_did = candidate.repo_did
                AND earlier.seq < candidate.seq
                AND earlier.status IN ('pending', 'leased', 'retry')
            )
          ORDER BY candidate.next_attempt_at, candidate.seq,
                   candidate.environment, candidate.source_generation
          FOR UPDATE SKIP LOCKED
          LIMIT \(boundedLimit)
        )
        UPDATE wire_ingestion_inbox inbox
        SET status = 'applied', next_attempt_at = \(asOf),
            failure_category = NULL, failure_reason = NULL,
            applied_at = \(asOf), dead_lettered_at = NULL,
            lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
            attempt_count = attempt_count + 1,
            expires_at = \(expiresAt), updated_at = \(asOf)
        FROM candidates
        WHERE inbox.environment = candidates.environment
          AND inbox.source_generation = candidates.source_generation
          AND inbox.seq = candidates.seq
          AND inbox.status IN ('pending', 'retry')
          AND inbox.next_attempt_at <= \(asOf)
        RETURNING inbox.seq
        """,
        logger: logger
      )
      var count = 0
      for try await _ in rows { count += 1 }
      return count
    }
  }

  private func acknowledgeScopedUnresolvedPassiveReferences(
    asOf: Date,
    limit: Int,
    sourceScope: WireInboxSourceScope
  ) async throws -> Int {
    let expiresAt = asOf.addingTimeInterval(300)
    let boundedLimit = max(1, min(limit, 5_000))
    return try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        WITH scoped_heads AS MATERIALIZED (
          SELECT DISTINCT ON (environment, source_generation, repo_did)
                 environment, source_generation, seq, repo_did, status, next_attempt_at,
                 event_kind, collection, operation, payload
          FROM wire_ingestion_inbox
          WHERE environment = \(sourceScope.environment)
            AND source_generation = ANY(\(sourceScope.sourceGenerations))
            AND status IN ('pending', 'leased', 'retry')
          ORDER BY environment, source_generation, repo_did, seq
        ),
        candidates AS (
          SELECT inbox.environment, inbox.source_generation, inbox.seq
          FROM scoped_heads scoped
          JOIN wire_ingestion_inbox inbox
            ON inbox.environment = scoped.environment
           AND inbox.source_generation = scoped.source_generation
           AND inbox.seq = scoped.seq
          WHERE scoped.status IN ('pending', 'retry')
            AND scoped.next_attempt_at <= \(asOf)
            AND scoped.event_kind = 'commit'
            AND scoped.collection IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
            AND scoped.operation IN ('create', 'update')
            AND NULLIF(BTRIM(COALESCE(
              scoped.payload #>> '{commit,record,subject,uri}',
              CASE
                WHEN jsonb_typeof(scoped.payload #> '{commit,record,subject}') = 'string'
                THEN scoped.payload #>> '{commit,record,subject}'
              END
            )), '') IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM wire_item_aliases alias
              WHERE alias.alias_key = COALESCE(
                scoped.payload #>> '{commit,record,subject,uri}',
                CASE
                  WHEN jsonb_typeof(scoped.payload #> '{commit,record,subject}') = 'string'
                  THEN scoped.payload #>> '{commit,record,subject}'
                END
              )
                AND alias.expires_at > \(asOf)
            )
          ORDER BY scoped.seq, scoped.source_generation
          FOR UPDATE OF inbox SKIP LOCKED
          LIMIT \(boundedLimit)
        )
        UPDATE wire_ingestion_inbox inbox
        SET status = 'applied', next_attempt_at = \(asOf),
            failure_category = NULL, failure_reason = NULL,
            applied_at = \(asOf), dead_lettered_at = NULL,
            lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
            attempt_count = attempt_count + 1,
            expires_at = \(expiresAt), updated_at = \(asOf)
        FROM candidates
        WHERE inbox.environment = candidates.environment
          AND inbox.source_generation = candidates.source_generation
          AND inbox.seq = candidates.seq
          AND inbox.environment = \(sourceScope.environment)
          AND inbox.source_generation = ANY(\(sourceScope.sourceGenerations))
          AND inbox.status IN ('pending', 'retry')
          AND inbox.next_attempt_at <= \(asOf)
        RETURNING inbox.seq
        """,
        logger: logger
      )
      var count = 0
      for try await _ in rows { count += 1 }
      return count
    }
  }

  func actionableBacklogHealth(asOf: Date) async throws -> WireInboxBacklogHealth {
    if let sourceScope {
      return try await scopedActionableBacklogHealth(asOf: asOf, sourceScope: sourceScope)
    }
    return try await pool.withTransaction(logger: logger) { connection in
      // This diagnostic uses the ready/expired-lease indexes and a hard query
      // timeout. A slow observability scan therefore releases its single pool
      // connection instead of competing indefinitely with the drain hot path.
      _ = try await connection.query(
        "SET LOCAL statement_timeout = '5s'",
        logger: logger
      )
      let rows = try await connection.query(
        """
        SELECT COALESCE(SUM(actionable_count), 0)::bigint, MIN(oldest_staged_at)
        FROM (
          SELECT COUNT(*)::bigint AS actionable_count,
                 MIN(staged_at) AS oldest_staged_at
          FROM wire_ingestion_inbox
          WHERE status IN ('pending', 'retry') AND next_attempt_at <= \(asOf)
          UNION ALL
          SELECT COUNT(*)::bigint AS actionable_count,
                 MIN(staged_at) AS oldest_staged_at
          FROM wire_ingestion_inbox
          WHERE status = 'leased' AND lease_expires_at <= \(asOf)
        ) actionable_branches
        """,
        logger: logger
      )
      for try await row in rows {
        let value = try row.decode((Int64, Date?).self)
        return WireInboxBacklogHealth(
          actionableEventCount: value.0,
          oldestActionableAgeSeconds: value.1.map { asOf.timeIntervalSince($0) }
        )
      }
      return WireInboxBacklogHealth(actionableEventCount: 0, oldestActionableAgeSeconds: nil)
    }
  }

  private func scopedActionableBacklogHealth(
    asOf: Date,
    sourceScope: WireInboxSourceScope
  ) async throws -> WireInboxBacklogHealth {
    return try await pool.withTransaction(logger: logger) { connection in
      _ = try await connection.query(
        "SET LOCAL statement_timeout = '5s'",
        logger: logger
      )
      let rows = try await connection.query(
        """
        WITH scoped_rows AS MATERIALIZED (
          SELECT environment, source_generation, seq, status, next_attempt_at,
                 lease_expires_at, staged_at
          FROM wire_ingestion_inbox
          WHERE environment = \(sourceScope.environment)
            AND source_generation = ANY(\(sourceScope.sourceGenerations))
            AND status IN ('pending', 'leased', 'retry')
          ORDER BY environment, source_generation, seq
        )
        SELECT COALESCE(SUM(actionable_count), 0)::bigint, MIN(oldest_staged_at)
        FROM (
          SELECT COUNT(*)::bigint AS actionable_count,
                 MIN(staged_at) AS oldest_staged_at
          FROM scoped_rows
          WHERE status IN ('pending', 'retry') AND next_attempt_at <= \(asOf)
          UNION ALL
          SELECT COUNT(*)::bigint AS actionable_count,
                 MIN(staged_at) AS oldest_staged_at
          FROM scoped_rows
          WHERE status = 'leased' AND lease_expires_at <= \(asOf)
        ) actionable_branches
        """,
        logger: logger
      )
      for try await row in rows {
        let value = try row.decode((Int64, Date?).self)
        return WireInboxBacklogHealth(
          actionableEventCount: value.0,
          oldestActionableAgeSeconds: value.1.map { asOf.timeIntervalSince($0) }
        )
      }
      return WireInboxBacklogHealth(actionableEventCount: 0, oldestActionableAgeSeconds: nil)
    }
  }

  func maintain(asOf: Date) async throws {
    try await pruneActiveGraph(asOf: asOf)
    try await mentionStore.pruneExpired(asOf: asOf)
    try await refreshCommunitiesIfNeeded(asOf: asOf)
    try await refreshRollups(asOf: asOf)
  }

  func deleteTerminal(asOf: Date, batchSize: Int) async throws -> Int {
    if let sourceScope {
      return try await deleteScopedTerminal(
        asOf: asOf, batchSize: batchSize, sourceScope: sourceScope)
    }
    return try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        DELETE FROM wire_ingestion_inbox
        WHERE (environment, source_generation, seq) IN (
          SELECT environment, source_generation, seq
          FROM wire_ingestion_inbox
          WHERE status IN ('applied', 'dead_letter') AND expires_at <= \(asOf)
          ORDER BY expires_at, environment, source_generation, seq
          FOR UPDATE SKIP LOCKED
          LIMIT \(max(1, min(batchSize, 20_000)))
        )
        RETURNING environment
        """,
        logger: logger
      )
      var deletedByEnvironment: [String: Int64] = [:]
      for try await row in rows {
        deletedByEnvironment[try row.decode(String.self), default: 0] += 1
      }
      for (environment, count) in deletedByEnvironment {
        try await connection.query(
          """
          UPDATE wire_ingestion_admission
          SET retained_rows = GREATEST(0, retained_rows - \(count)), updated_at = \(asOf)
          WHERE environment = \(environment)
          """,
          logger: logger
        )
      }
      return deletedByEnvironment.values.reduce(0) { $0 + Int($1) }
    }
  }

  private func deleteScopedTerminal(
    asOf: Date,
    batchSize: Int,
    sourceScope: WireInboxSourceScope
  ) async throws -> Int {
    try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        DELETE FROM wire_ingestion_inbox
        WHERE (environment, source_generation, seq) IN (
          SELECT environment, source_generation, seq
          FROM wire_ingestion_inbox
          WHERE environment = \(sourceScope.environment)
            AND source_generation = ANY(\(sourceScope.sourceGenerations))
            AND status IN ('applied', 'dead_letter') AND expires_at <= \(asOf)
          ORDER BY expires_at, environment, source_generation, seq
          FOR UPDATE SKIP LOCKED
          LIMIT \(max(1, min(batchSize, 20_000)))
        )
          AND environment = \(sourceScope.environment)
          AND source_generation = ANY(\(sourceScope.sourceGenerations))
        RETURNING environment
        """,
        logger: logger
      )
      var deletedByEnvironment: [String: Int64] = [:]
      for try await row in rows {
        deletedByEnvironment[try row.decode(String.self), default: 0] += 1
      }
      for (environment, count) in deletedByEnvironment {
        try await connection.query(
          """
          UPDATE wire_ingestion_admission
          SET retained_rows = GREATEST(0, retained_rows - \(count)), updated_at = \(asOf)
          WHERE environment = \(environment)
          """,
          logger: logger
        )
      }
      return deletedByEnvironment.values.reduce(0) { $0 + Int($1) }
    }
  }

  private func process(_ event: InboxEvent, asOf: Date) async throws -> Bool {
    do {
      try await apply(event, asOf: asOf)
      try await finish(event, status: "applied", retryAt: asOf, reason: nil, asOf: asOf)
      return true
    } catch ApplyError.unresolvedReference {
      if asOf.timeIntervalSince(event.eventTime) < 24 * 3_600 {
        try await finish(
          event,
          status: "retry",
          retryAt: asOf.addingTimeInterval(30),
          reason: "unresolved_subject",
          asOf: asOf
        )
      } else {
        try await finish(
          event,
          status: "dead_letter",
          retryAt: asOf,
          reason: "unresolved_subject_expired",
          asOf: asOf
        )
      }
      return false
    } catch ApplyError.unresolvedPublication {
      if asOf.timeIntervalSince(event.eventTime) < 24 * 3_600 {
        try await finish(
          event,
          status: "retry",
          retryAt: asOf.addingTimeInterval(
            Self.publicationRetryDelay(attemptCount: event.attemptCount)),
          reason: "unresolved_publication",
          asOf: asOf
        )
      } else {
        try await finish(
          event,
          status: "dead_letter",
          retryAt: asOf,
          reason: "unresolved_publication_expired",
          asOf: asOf
        )
      }
      return false
    } catch ApplyError.malformed {
      try await finish(
        event,
        status: "dead_letter",
        retryAt: asOf,
        reason: "malformed_event",
        asOf: asOf
      )
      return false
    } catch {
      let terminal = event.attemptCount >= 8
      try await finish(
        event,
        status: terminal ? "dead_letter" : "retry",
        retryAt: terminal ? asOf : asOf.addingTimeInterval(60),
        reason: String(reflecting: error).prefix(500).description,
        asOf: asOf
      )
      return false
    }
  }

  private func claim(asOf: Date) async throws -> [InboxEvent] {
    if let sourceScope {
      return try await claimScoped(asOf: asOf, sourceScope: sourceScope)
    }
    let token = UUID().uuidString.lowercased()
    let leaseUntil = asOf.addingTimeInterval(120)
    let claimLimit = Self.boundedClaimLimit(
      batchSize: batchSize,
      maximumConcurrentEvents: maximumConcurrentEvents
    )
    let rows = try await pool.query(
      """
      WITH pending_retry_candidates AS (
        SELECT environment, source_generation, seq, next_attempt_at AS eligible_at
        FROM wire_ingestion_inbox candidate
        WHERE candidate.status IN ('pending', 'retry')
          AND candidate.next_attempt_at <= \(asOf)
          AND NOT EXISTS (
            SELECT 1 FROM wire_ingestion_inbox earlier
            WHERE earlier.environment = candidate.environment
              AND earlier.source_generation = candidate.source_generation
              AND earlier.repo_did = candidate.repo_did
              AND earlier.seq < candidate.seq
              AND earlier.status IN ('pending', 'leased', 'retry')
          )
        ORDER BY candidate.next_attempt_at, candidate.seq,
                 candidate.environment, candidate.source_generation
        FOR UPDATE SKIP LOCKED
        LIMIT \(claimLimit)
      ),
      expired_lease_candidates AS (
        SELECT environment, source_generation, seq, lease_expires_at AS eligible_at
        FROM wire_ingestion_inbox candidate
        WHERE candidate.status = 'leased'
          AND candidate.lease_expires_at <= \(asOf)
          AND NOT EXISTS (
            SELECT 1 FROM wire_ingestion_inbox earlier
            WHERE earlier.environment = candidate.environment
              AND earlier.source_generation = candidate.source_generation
              AND earlier.repo_did = candidate.repo_did
              AND earlier.seq < candidate.seq
              AND earlier.status IN ('pending', 'leased', 'retry')
          )
        ORDER BY candidate.lease_expires_at, candidate.seq,
                 candidate.environment, candidate.source_generation
        FOR UPDATE SKIP LOCKED
        LIMIT \(claimLimit)
      ),
      candidates AS (
        SELECT environment, source_generation, seq, eligible_at
        FROM pending_retry_candidates
        UNION ALL
        SELECT environment, source_generation, seq, eligible_at
        FROM expired_lease_candidates
        ORDER BY eligible_at, seq, environment, source_generation
        LIMIT \(claimLimit)
      )
      UPDATE wire_ingestion_inbox inbox
      SET status = 'leased', lease_owner = 'wire-worker', lease_token = \(token),
          lease_expires_at = \(leaseUntil), attempt_count = attempt_count + 1,
          updated_at = \(asOf)
      FROM candidates
      WHERE inbox.environment = candidates.environment
        AND inbox.source_generation = candidates.source_generation
        AND inbox.seq = candidates.seq
      RETURNING inbox.environment, inbox.source_generation, inbox.seq,
                inbox.source_host, inbox.cursor_kind, inbox.event_kind,
                inbox.repo_did, inbox.collection, inbox.operation, inbox.record_key,
                inbox.payload::text, inbox.event_time, inbox.lease_token, inbox.attempt_count
      """,
      logger: logger
    )
    var result: [InboxEvent] = []
    for try await row in rows {
      let value = try row.decode(
        (
          String, String, Int64, String, String, String, String, String?, String?, String?, String,
          Date, String, Int
        ).self
      )
      result.append(
        InboxEvent(
          environment: value.0,
          sourceGeneration: value.1,
          sequence: value.2,
          sourceHost: value.3,
          cursorKind: value.4,
          eventKind: value.5,
          repoDID: value.6,
          collection: value.7,
          operation: value.8,
          recordKey: value.9,
          payloadJSON: value.10,
          eventTime: value.11,
          leaseToken: value.12,
          attemptCount: value.13
        )
      )
    }
    return result.sorted { $0.sequence < $1.sequence }
  }

  private func claimScopedPassiveDeletes(asOf: Date) async throws -> [InboxEvent] {
    guard let sourceScope else { return [] }
    let token = UUID().uuidString.lowercased()
    let leaseUntil = asOf.addingTimeInterval(120)
    let claimLimit = Self.boundedClaimLimit(
      batchSize: batchSize,
      maximumConcurrentEvents: maximumConcurrentEvents
    )
    let rows = try await pool.query(
      """
      WITH scoped_active AS MATERIALIZED (
        SELECT environment, source_generation, seq, repo_did, status,
               next_attempt_at, lease_expires_at, event_kind, collection,
               operation, record_key
        FROM wire_ingestion_inbox
        WHERE environment = \(sourceScope.environment)
          AND source_generation = ANY(\(sourceScope.sourceGenerations))
          AND status IN ('pending', 'leased', 'retry')
      ),
      repo_barriers AS MATERIALIZED (
        SELECT environment, source_generation, repo_did,
               MIN(seq) FILTER (
                 WHERE event_kind <> 'commit'
                    OR collection IS NULL
                    OR collection NOT IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
                    OR operation IS DISTINCT FROM 'delete'
                    OR record_key IS NULL
               ) AS barrier_seq
        FROM scoped_active
        GROUP BY environment, source_generation, repo_did
      ),
      candidates AS (
        SELECT inbox.environment, inbox.source_generation, inbox.seq
        FROM scoped_active candidate
        JOIN repo_barriers barrier
          ON barrier.environment = candidate.environment
         AND barrier.source_generation = candidate.source_generation
         AND barrier.repo_did = candidate.repo_did
        JOIN wire_ingestion_inbox inbox
          ON inbox.environment = candidate.environment
         AND inbox.source_generation = candidate.source_generation
         AND inbox.seq = candidate.seq
        WHERE (
            (candidate.status IN ('pending', 'retry')
              AND candidate.next_attempt_at <= \(asOf))
            OR (candidate.status = 'leased'
              AND candidate.lease_expires_at <= \(asOf))
          )
          AND candidate.event_kind = 'commit'
          AND candidate.collection IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
          AND candidate.operation = 'delete'
          AND candidate.record_key IS NOT NULL
          AND (barrier.barrier_seq IS NULL OR candidate.seq < barrier.barrier_seq)
        ORDER BY COALESCE(candidate.lease_expires_at, candidate.next_attempt_at), candidate.seq
        FOR UPDATE OF inbox SKIP LOCKED
        LIMIT \(claimLimit)
      )
      UPDATE wire_ingestion_inbox inbox
      SET status = 'leased', lease_owner = 'wire-worker', lease_token = \(token),
          lease_expires_at = \(leaseUntil), attempt_count = attempt_count + 1,
          updated_at = \(asOf)
      FROM candidates
      WHERE inbox.environment = candidates.environment
        AND inbox.source_generation = candidates.source_generation
        AND inbox.seq = candidates.seq
        AND inbox.environment = \(sourceScope.environment)
        AND inbox.source_generation = ANY(\(sourceScope.sourceGenerations))
      RETURNING inbox.environment, inbox.source_generation, inbox.seq,
                inbox.source_host, inbox.cursor_kind, inbox.event_kind,
                inbox.repo_did, inbox.collection, inbox.operation, inbox.record_key,
                inbox.payload::text, inbox.event_time, inbox.lease_token, inbox.attempt_count
      """,
      logger: logger
    )
    var result: [InboxEvent] = []
    for try await row in rows {
      let value = try row.decode(
        (
          String, String, Int64, String, String, String, String, String?, String?, String?, String,
          Date, String, Int
        ).self
      )
      result.append(
        InboxEvent(
          environment: value.0,
          sourceGeneration: value.1,
          sequence: value.2,
          sourceHost: value.3,
          cursorKind: value.4,
          eventKind: value.5,
          repoDID: value.6,
          collection: value.7,
          operation: value.8,
          recordKey: value.9,
          payloadJSON: value.10,
          eventTime: value.11,
          leaseToken: value.12,
          attemptCount: value.13
        )
      )
    }
    return result.sorted { $0.sequence < $1.sequence }
  }

  private func claimScoped(
    asOf: Date,
    sourceScope: WireInboxSourceScope
  ) async throws -> [InboxEvent] {
    let token = UUID().uuidString.lowercased()
    let leaseUntil = asOf.addingTimeInterval(120)
    let claimLimit = Self.boundedClaimLimit(
      batchSize: batchSize,
      maximumConcurrentEvents: maximumConcurrentEvents
    )
    let rows = try await pool.query(
      """
      WITH scoped_heads AS MATERIALIZED (
        SELECT DISTINCT ON (environment, source_generation, repo_did)
               environment, source_generation, seq, repo_did, status,
               next_attempt_at, lease_expires_at
        FROM wire_ingestion_inbox
        WHERE environment = \(sourceScope.environment)
          AND source_generation = ANY(\(sourceScope.sourceGenerations))
          AND status IN ('pending', 'leased', 'retry')
        ORDER BY environment, source_generation, repo_did, seq
      ),
      pending_retry_candidates AS (
        SELECT inbox.environment, inbox.source_generation, inbox.seq,
               scoped.next_attempt_at AS eligible_at
        FROM scoped_heads scoped
        JOIN wire_ingestion_inbox inbox
          ON inbox.environment = scoped.environment
         AND inbox.source_generation = scoped.source_generation
         AND inbox.seq = scoped.seq
        WHERE scoped.status IN ('pending', 'retry')
          AND scoped.next_attempt_at <= \(asOf)
        ORDER BY scoped.seq, scoped.source_generation
        FOR UPDATE OF inbox SKIP LOCKED
        LIMIT \(claimLimit)
      ),
      expired_lease_candidates AS (
        SELECT inbox.environment, inbox.source_generation, inbox.seq,
               scoped.lease_expires_at AS eligible_at
        FROM scoped_heads scoped
        JOIN wire_ingestion_inbox inbox
          ON inbox.environment = scoped.environment
         AND inbox.source_generation = scoped.source_generation
         AND inbox.seq = scoped.seq
        WHERE scoped.status = 'leased'
          AND scoped.lease_expires_at <= \(asOf)
        ORDER BY scoped.seq, scoped.source_generation
        FOR UPDATE OF inbox SKIP LOCKED
        LIMIT \(claimLimit)
      ),
      candidates AS (
        SELECT environment, source_generation, seq, eligible_at
        FROM pending_retry_candidates
        UNION ALL
        SELECT environment, source_generation, seq, eligible_at
        FROM expired_lease_candidates
        ORDER BY eligible_at, seq, environment, source_generation
        LIMIT \(claimLimit)
      )
      UPDATE wire_ingestion_inbox inbox
      SET status = 'leased', lease_owner = 'wire-worker', lease_token = \(token),
          lease_expires_at = \(leaseUntil), attempt_count = attempt_count + 1,
          updated_at = \(asOf)
      FROM candidates
      WHERE inbox.environment = candidates.environment
        AND inbox.source_generation = candidates.source_generation
        AND inbox.seq = candidates.seq
        AND inbox.environment = \(sourceScope.environment)
        AND inbox.source_generation = ANY(\(sourceScope.sourceGenerations))
      RETURNING inbox.environment, inbox.source_generation, inbox.seq,
                inbox.source_host, inbox.cursor_kind, inbox.event_kind,
                inbox.repo_did, inbox.collection, inbox.operation, inbox.record_key,
                inbox.payload::text, inbox.event_time, inbox.lease_token, inbox.attempt_count
      """,
      logger: logger
    )
    var result: [InboxEvent] = []
    for try await row in rows {
      let value = try row.decode(
        (
          String, String, Int64, String, String, String, String, String?, String?, String?, String,
          Date, String, Int
        ).self
      )
      result.append(
        InboxEvent(
          environment: value.0,
          sourceGeneration: value.1,
          sequence: value.2,
          sourceHost: value.3,
          cursorKind: value.4,
          eventKind: value.5,
          repoDID: value.6,
          collection: value.7,
          operation: value.8,
          recordKey: value.9,
          payloadJSON: value.10,
          eventTime: value.11,
          leaseToken: value.12,
          attemptCount: value.13
        )
      )
    }
    return result.sorted { $0.sequence < $1.sequence }
  }

  private func apply(_ event: InboxEvent, asOf: Date) async throws {
    if Self.isPayloadNormalizationFailure(event.payloadJSON) {
      throw ApplyError.malformed
    }
    if event.eventKind == "account" {
      try await applyAccountLifecycle(event, asOf: asOf)
      return
    }
    guard event.eventKind == "commit", let collection = event.collection,
      let operation = event.operation, let sourceURI = event.sourceURI
    else { return }
    if operation == "delete" {
      if collection == "site.standard.publication" {
        try await publicationResolver.remove(
          publicationURI: sourceURI,
          observedAt: event.eventTime
        )
      } else {
        try await retract(sourceURI: sourceURI, eventTime: event.eventTime, asOf: asOf)
      }
      return
    }
    guard operation == "create" || operation == "update",
      let document = try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8))
        as? [String: Any],
      let commit = document["commit"] as? [String: Any],
      let record = commit["record"] as? [String: Any]
    else { throw ApplyError.malformed }

    switch collection {
    case "site.standard.publication":
      guard
        let metadata = WirePublicationMetadata.parse(
          publicationURI: sourceURI,
          repoDID: event.repoDID,
          record: record
        )
      else { throw ApplyError.malformed }
      try await publicationResolver.observe(metadata, asOf: event.eventTime)
    case "site.standard.document", "site.standard.entry":
      try await applyArticle(record: record, event: event, sourceURI: sourceURI, asOf: asOf)
    case "app.bsky.feed.post":
      try await applyPost(record: record, event: event, sourceURI: sourceURI, asOf: asOf)
    case "site.standard.graph.recommend":
      try await applyReferenceSignal(
        record: record,
        event: event,
        sourceURI: sourceURI,
        kind: "recommendation",
        asOf: asOf
      )
    case "app.thesocialwire.wireFeedback":
      try await applyArticleFeedback(
        record: record,
        event: event,
        sourceURI: sourceURI,
        asOf: asOf
      )
    case "app.bsky.feed.like":
      try await applyReferenceSignal(
        record: record, event: event, sourceURI: sourceURI, kind: "like", asOf: asOf
      )
    case "app.bsky.feed.repost":
      try await applyReferenceSignal(
        record: record, event: event, sourceURI: sourceURI, kind: "repost", asOf: asOf
      )
    case "app.bsky.graph.follow":
      try await applyFollow(record: record, event: event, sourceURI: sourceURI, asOf: asOf)
    default:
      return
    }
  }

  static func isPayloadNormalizationFailure(_ payloadJSON: String) -> Bool {
    guard
      let document = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))
        as? [String: Any],
      let error = document["$wireIngestionError"] as? [String: Any]
    else { return false }
    return error["code"] as? String == "payload_normalization_failed"
  }

  private func applyArticle(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    let resolved: WireResolvedStandardSiteDocument
    do {
      resolved = try await WireStandardSiteDocumentResolver.resolve(
        record: record,
        publicationResolver: publicationResolver,
        asOf: asOf
      )
    } catch WireStandardSiteDocumentError.unaddressableDocument {
      return
    } catch WireStandardSiteDocumentError.unresolvedPublication {
      throw ApplyError.unresolvedPublication
    } catch WireStandardSiteDocumentError.malformedDocument,
      WireStandardSiteDocumentError.invalidPublication
    {
      throw ApplyError.malformed
    }
    guard let identity = WireCanonicalizer.canonicalize(resolved.canonicalURL),
      let host = URL(string: identity.canonicalURL)?.host
    else { throw ApplyError.malformed }
    let targetKind = WireContentQualityClassifier.targetKind(
      for: identity.canonicalURL, standardSite: true)
    guard targetKind.canCreateItem else { return }
    let title = Self.firstString(record, keys: ["title", "name"]) ?? host
    let summary = Self.firstString(record, keys: ["summary", "description", "text", "textContent"])
    let thumbnail = Self.firstString(
      record,
      keys: ["thumbnail", "thumbnailUrl", "coverImageUrl", "image"]
    )
    let language = Self.primaryLanguage(Self.firstString(record, keys: ["lang", "language"]))
    let publishedAt = Self.date(Self.firstString(record, keys: ["publishedAt", "createdAt"]))
    let publicationID = resolved.publicationURI
    let authorName = Self.firstString(
      record,
      keys: ["authorName", "displayName", "byline", "author"]
    )
    let topicKeys = (record["tags"] as? [String] ?? []).map { $0.lowercased() }
    let actorHash = try actorHasher.hash(event.repoDID)
    try await upsertItem(
      identity: identity,
      representativeURI: sourceURI,
      authorDID: event.repoDID,
      sourceName: resolved.publicationName
        ?? Self.firstString(record, keys: ["publicationName", "siteName"]) ?? host,
      host: host,
      publicationID: publicationID,
      authorName: authorName,
      topicKeys: topicKeys,
      title: title,
      summary: summary,
      thumbnail: thumbnail,
      language: language,
      publishedAt: publishedAt,
      provenance: ["standard_site"],
      confidence: 0.9,
      presentationSource: "standard_site",
      presentationPriority: 400,
      publicationHomepageURL: resolved.publicationHomepageURL
        ?? Self.homepageURL(for: identity.canonicalURL),
      publicationIconURL: nil,
      sourceText: nil,
      targetKind: targetKind,
      inspectionURL: resolved.canonicalURL,
      asOf: asOf
    )
    try await upsertAlias(
      alias: sourceURI, type: "at_uri", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertAlias(
      alias: identity.canonicalURL, type: "url", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertActor(hash: actorHash, asOf: asOf)
    try await insertSignal(
      event: event,
      canonicalKey: identity.canonicalKey,
      actorHash: actorHash,
      sourceURI: sourceURI,
      kind: "publication",
      asOf: asOf
    )
  }

  static func publicationRetryDelay(attemptCount: Int) -> TimeInterval {
    let exponent = min(max(attemptCount - 1, 0), 4)
    return min(300 * pow(2, Double(exponent)), 3_600)
  }

  private func applyPost(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    guard let rawURL = Self.externalURL(record),
      WireContentQualityClassifier.targetKind(for: rawURL).canCreateItem,
      let identity = WireCanonicalizer.canonicalize(rawURL),
      let host = URL(string: identity.canonicalURL)?.host
    else {
      if Self.missingPostLinkRequiresRetraction(operation: event.operation) {
        try await retract(sourceURI: sourceURI, eventTime: event.eventTime, asOf: asOf)
      }
      return
    }
    let text = Self.firstString(record, keys: ["text"])
    let embedded = WireEmbeddedCardMetadata.extract(
      from: record,
      canonicalURL: identity.canonicalURL
    )
    let fallbackTitle: String?
    if let firstLine = text?.split(separator: "\n").first {
      let value = String(firstLine)
      fallbackTitle = value.isEmpty ? nil : String(value.prefix(200))
    } else {
      fallbackTitle = nil
    }
    let title = embedded?.title ?? fallbackTitle ?? host
    let actorHash = try actorHasher.hash(event.repoDID)
    try await upsertItem(
      identity: identity,
      representativeURI: sourceURI,
      authorDID: nil,
      sourceName: embedded?.siteName ?? host,
      host: host,
      publicationID: nil,
      authorName: nil,
      topicKeys: [],
      title: title,
      summary: embedded?.description ?? text,
      thumbnail: embedded?.imageURL,
      language: Self.primaryLanguage(Self.firstString(record, keys: ["langs", "lang"])),
      publishedAt: Self.date(Self.firstString(record, keys: ["createdAt"])),
      provenance: [Self.containsQuote(record) ? "quote" : "direct_share"],
      confidence: 0.6,
      presentationSource: embedded == nil ? "fallback" : "embedded_card",
      presentationPriority: embedded == nil ? 100 : 200,
      publicationHomepageURL: Self.homepageURL(for: identity.canonicalURL),
      publicationIconURL: embedded?.iconURL,
      sourceText: text,
      targetKind: .externalArticle,
      inspectionURL: rawURL,
      asOf: asOf
    )
    if let embedded {
      try await linkMetadataStore.seedEmbedded(
        canonicalKey: identity.canonicalKey,
        metadata: embedded,
        asOf: asOf
      )
    }
    try await upsertAlias(
      alias: sourceURI, type: "at_uri", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertAlias(
      alias: identity.canonicalURL, type: "url", canonicalKey: identity.canonicalKey, asOf: asOf)
    try await upsertActor(hash: actorHash, asOf: asOf)
    let kind = Self.containsQuote(record) ? "quote" : "share"
    try await insertSignal(
      event: event,
      canonicalKey: identity.canonicalKey,
      actorHash: actorHash,
      sourceURI: sourceURI,
      kind: kind,
      asOf: asOf
    )
    try await mentionStore.replaceMentions(
      sourceURI: sourceURI,
      canonicalKey: identity.canonicalKey,
      subjectDIDs: WireTalkedAccountMentionExtractor.subjects(in: record),
      speakerKeyHash: actorHash,
      occurredAt: event.eventTime,
      expiresAt: event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention)
    )
  }

  static func missingPostLinkRequiresRetraction(operation: String?) -> Bool {
    operation == "update"
  }

  private func applyReferenceSignal(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    kind: String,
    asOf: Date
  ) async throws {
    guard let subjectURI = Self.referenceSubjectURI(
      record: record,
      collection: event.collection
    ) else { throw ApplyError.malformed }
    guard let canonicalKey = try await canonicalKey(alias: subjectURI) else {
      if Self.retriesUnresolvedReference(collection: event.collection) {
        throw ApplyError.unresolvedReference
      }
      return
    }
    let actorHash = try actorHasher.hash(event.repoDID)
    try await upsertActor(hash: actorHash, asOf: asOf)
    try await appendProvenance(kind, canonicalKey: canonicalKey, asOf: asOf)
    try await insertSignal(
      event: event,
      canonicalKey: canonicalKey,
      actorHash: actorHash,
      sourceURI: sourceURI,
      kind: kind,
      asOf: asOf
    )
  }

  private func applyArticleFeedback(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    guard let canonicalURL = record["canonicalUrl"] as? String,
      let identity = WireCanonicalizer.canonicalize(canonicalURL),
      let value = record["value"] as? String,
      value == "good" || value == "not_good"
    else { throw ApplyError.malformed }
    guard try await itemExists(canonicalKey: identity.canonicalKey) else {
      if Self.retriesUnresolvedReference(collection: event.collection) {
        throw ApplyError.unresolvedReference
      }
      return
    }

    let actorHash = try actorHasher.hash(event.repoDID)
    try await upsertActor(hash: actorHash, asOf: asOf)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(sourceURI), 0))",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_article_feedback WHERE source_uri = \(sourceURI) AND occurred_at <= \(event.eventTime)",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_article_feedback
          (canonical_key, actor_key_hash, source_uri, feedback_value, occurred_at, expires_at)
        VALUES
          (\(identity.canonicalKey), \(actorHash), \(sourceURI), \(value), \(event.eventTime),
           \(event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention)))
        ON CONFLICT (canonical_key, actor_key_hash) DO UPDATE
        SET source_uri = EXCLUDED.source_uri,
            feedback_value = EXCLUDED.feedback_value,
            occurred_at = EXCLUDED.occurred_at,
            expires_at = EXCLUDED.expires_at
        WHERE wire_article_feedback.occurred_at <= EXCLUDED.occurred_at
        """,
        logger: logger
      )
    }
  }

  private func itemExists(canonicalKey: String) async throws -> Bool {
    let rows = try await pool.query(
      "SELECT EXISTS(SELECT 1 FROM wire_items WHERE canonical_key = \(canonicalKey) AND expires_at > NOW())",
      logger: logger
    )
    for try await row in rows { return try row.decode(Bool.self) }
    return false
  }

  private func applyFollow(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    guard let subject = record["subject"] as? String else { throw ApplyError.malformed }
    let follower = try actorHasher.hash(event.repoDID)
    let followee = try actorHasher.hash(subject)
    if Self.isSelfFollow(follower: follower, followee: followee) {
      try await pool.query(
        "DELETE FROM wire_follow_edges WHERE source_uri = \(sourceURI)",
        logger: logger
      )
      return
    }
    guard try await isActiveActor(hash: follower, asOf: asOf) else { return }
    let expiresAt = asOf.addingTimeInterval(WireDataPolicy.followEdgeRetention)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM wire_follow_edges WHERE source_uri = \(sourceURI)",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_follow_edges
          (source_uri, follower_key_hash, followee_key_hash, observed_at, expires_at)
        VALUES (\(sourceURI), \(follower), \(followee), \(asOf), \(expiresAt))
        ON CONFLICT (follower_key_hash, followee_key_hash) DO UPDATE
        SET source_uri = EXCLUDED.source_uri, observed_at = EXCLUDED.observed_at,
            expires_at = EXCLUDED.expires_at
        """,
        logger: logger
      )
    }
    try await pool.query(
      """
      DELETE FROM wire_follow_edges edge
      WHERE edge.follower_key_hash = \(follower)
        AND edge.followee_key_hash IN (
          SELECT followee_key_hash FROM wire_follow_edges
          WHERE follower_key_hash = \(follower)
          ORDER BY observed_at DESC, followee_key_hash
          OFFSET \(WireDataPolicy.maximumFollowEdgesPerActor)
        )
      """,
      logger: logger
    )
  }

  static func isSelfFollow(follower: String, followee: String) -> Bool {
    follower == followee
  }

  private func applyAccountLifecycle(_ event: InboxEvent, asOf: Date) async throws {
    guard
      let document = try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8))
        as? [String: Any],
      let account = document["account"] as? [String: Any],
      account["active"] as? Bool == false
    else { return }
    let actorHash = try actorHasher.hash(event.repoDID)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "UPDATE wire_items SET eligible = FALSE, updated_at = \(asOf) WHERE author_key = \(event.repoDID)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE actor_key_hash = \(actorHash)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_follow_edges WHERE follower_key_hash = \(actorHash) OR followee_key_hash = \(actorHash)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_active_actors WHERE actor_key_hash = \(actorHash)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_article_feedback WHERE actor_key_hash = \(actorHash)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_publications WHERE repo_did = \(event.repoDID)",
        logger: logger
      )
    }
    try await mentionStore.removeActor(did: event.repoDID, actorKeyHash: actorHash)
  }

  private func retract(sourceURI: String, eventTime: Date, asOf: Date) async throws {
    try await mentionStore.retract(sourceURI: sourceURI, through: eventTime)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(sourceURI), 0))",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(sourceURI) AND occurred_at <= \(eventTime)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_follow_edges WHERE source_uri = \(sourceURI)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_article_feedback WHERE source_uri = \(sourceURI) AND occurred_at <= \(eventTime)",
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_item_aliases alias
        WHERE alias.alias_key = \(sourceURI)
          AND NOT EXISTS (
            SELECT 1 FROM wire_signal_events signal
            WHERE signal.source_uri = \(sourceURI) AND signal.occurred_at > \(eventTime)
          )
        """,
        logger: logger
      )
      try await connection.query(
        "UPDATE wire_items SET updated_at = \(asOf) WHERE representative_uri = \(sourceURI)",
        logger: logger
      )
    }
  }

  private func upsertItem(
    identity: WireCanonicalIdentity,
    representativeURI: String,
    authorDID: String?,
    sourceName: String,
    host: String,
    publicationID: String?,
    authorName: String?,
    topicKeys: [String],
    title: String,
    summary: String?,
    thumbnail: String?,
    language: String,
    publishedAt: Date?,
    provenance: [String],
    confidence: Double,
    presentationSource: String,
    presentationPriority: Int,
    publicationHomepageURL: String?,
    publicationIconURL: String?,
    sourceText: String?,
    targetKind: WireTargetKind,
    inspectionURL: String,
    asOf: Date
  ) async throws {
    let provenanceJSON = String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self)
    let topicsJSON = String(decoding: try JSONEncoder().encode(topicKeys), as: UTF8.self)
    let commercial = WireContentQualityClassifier.assess(
      canonicalURL: inspectionURL,
      title: title,
      summary: summary,
      sourceText: sourceText,
      topicKeys: topicKeys
    )
    let commercialReasonsJSON = String(
      decoding: try JSONEncoder().encode(commercial.reasons.map(\.rawValue)), as: UTF8.self)
    var presentation: [String: Any] = [
      "metadataSource": presentationSource,
      "sourcePriority": presentationPriority,
    ]
    presentation["homepageUrl"] = publicationHomepageURL
    presentation["iconUrl"] = publicationIconURL
    let presentationJSON = String(
      decoding: try JSONSerialization.data(withJSONObject: presentation),
      as: UTF8.self
    )
    let expiresAt = asOf.addingTimeInterval(WireDataPolicy.itemRetention)
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, representative_uri, publication_id, author_key,
         source_domain, source_name, author_name, title, summary, thumbnail_url,
         publication_homepage_url, publication_icon_url,
         language_code, topic_keys, presentation_snapshot, provenance, published_at,
         first_seen_at, last_seen_at, last_signal_at,
         source_confidence, eligible, target_kind, commercial_score, commercial_class,
         commercial_reasons, expires_at, updated_at)
      VALUES
        (\(identity.canonicalKey), \(identity.canonicalURL), \(representativeURI), \(publicationID),
         \(authorDID), \(host), \(sourceName), \(authorName), \(title), \(summary), \(thumbnail),
         \(publicationHomepageURL), \(publicationIconURL),
         \(language), \(topicsJSON)::jsonb, \(presentationJSON)::jsonb, \(provenanceJSON)::jsonb,
         \(publishedAt), \(asOf), \(asOf), \(asOf), \(confidence), TRUE, \(targetKind.rawValue),
         \(commercial.score), \(commercial.classification.rawValue),
         \(commercialReasonsJSON)::jsonb, \(expiresAt), \(asOf))
      ON CONFLICT (canonical_key) DO UPDATE SET
        canonical_url = EXCLUDED.canonical_url,
        representative_uri = COALESCE(wire_items.representative_uri, EXCLUDED.representative_uri),
        publication_id = COALESCE(wire_items.publication_id, EXCLUDED.publication_id),
        author_key = COALESCE(wire_items.author_key, EXCLUDED.author_key),
        author_name = COALESCE(wire_items.author_name, EXCLUDED.author_name),
        source_name = CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN EXCLUDED.source_name ELSE wire_items.source_name END,
        title = CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN EXCLUDED.title ELSE wire_items.title END,
        summary = CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN COALESCE(EXCLUDED.summary, wire_items.summary) ELSE wire_items.summary END,
        thumbnail_url = CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN COALESCE(EXCLUDED.thumbnail_url, wire_items.thumbnail_url) ELSE wire_items.thumbnail_url END,
        presentation_snapshot = CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN EXCLUDED.presentation_snapshot ELSE wire_items.presentation_snapshot END,
        publication_homepage_url = COALESCE(
          EXCLUDED.publication_homepage_url, wire_items.publication_homepage_url),
        publication_icon_url = COALESCE(
          EXCLUDED.publication_icon_url, wire_items.publication_icon_url),
        language_code = CASE WHEN wire_items.language_code = 'und'
          THEN EXCLUDED.language_code ELSE wire_items.language_code END,
        topic_keys = CASE WHEN jsonb_array_length(wire_items.topic_keys) = 0
          THEN EXCLUDED.topic_keys ELSE wire_items.topic_keys END,
        provenance = (
          SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
          FROM (
            SELECT DISTINCT value
            FROM jsonb_array_elements_text(wire_items.provenance || EXCLUDED.provenance)
          ) unique_provenance
        ), target_kind = CASE WHEN wire_items.target_kind = 'standard_site_document'
          THEN wire_items.target_kind ELSE EXCLUDED.target_kind END,
        commercial_score = GREATEST(wire_items.commercial_score, EXCLUDED.commercial_score),
        commercial_class = CASE
          WHEN wire_items.commercial_score > EXCLUDED.commercial_score
          THEN wire_items.commercial_class ELSE EXCLUDED.commercial_class END,
        commercial_reasons = CASE
          WHEN wire_items.commercial_score > EXCLUDED.commercial_score
          THEN wire_items.commercial_reasons ELSE EXCLUDED.commercial_reasons END,
        published_at = COALESCE(wire_items.published_at, EXCLUDED.published_at),
        last_seen_at = EXCLUDED.last_seen_at, last_signal_at = EXCLUDED.last_signal_at,
        source_confidence = GREATEST(wire_items.source_confidence, EXCLUDED.source_confidence),
        expires_at = GREATEST(wire_items.expires_at, EXCLUDED.expires_at), updated_at = EXCLUDED.updated_at
      """,
      logger: logger
    )
  }

  private func upsertAlias(
    alias: String,
    type: String,
    canonicalKey: String,
    asOf: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO wire_item_aliases (alias_key, canonical_key, alias_type, expires_at)
      VALUES (\(alias), \(canonicalKey), \(type), \(asOf.addingTimeInterval(WireDataPolicy.itemRetention)))
      ON CONFLICT (alias_key) DO UPDATE SET canonical_key = EXCLUDED.canonical_key,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  private func appendProvenance(
    _ kind: String,
    canonicalKey: String,
    asOf: Date
  ) async throws {
    guard ["recommendation", "like", "repost"].contains(kind) else { return }
    try await pool.query(
      """
      UPDATE wire_items item
      SET provenance = (
        SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
        FROM (
          SELECT DISTINCT value
          FROM jsonb_array_elements_text(item.provenance || to_jsonb(ARRAY[\(kind)]::text[]))
        ) unique_provenance
      ), updated_at = \(asOf)
      WHERE canonical_key = \(canonicalKey)
      """,
      logger: logger
    )
  }

  private func canonicalKey(alias: String) async throws -> String? {
    let rows = try await pool.query(
      "SELECT canonical_key FROM wire_item_aliases WHERE alias_key = \(alias) AND expires_at > NOW() LIMIT 1",
      logger: logger
    )
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }

  private func upsertActor(hash: String, asOf: Date) async throws {
    try await pool.query(
      """
      INSERT INTO wire_active_actors
        (actor_key_hash, first_active_at, last_active_at, public_signal_count, expires_at)
      VALUES (\(hash), \(asOf), \(asOf), 1, \(asOf.addingTimeInterval(WireDataPolicy.activeActorRetention)))
      ON CONFLICT (actor_key_hash) DO UPDATE SET last_active_at = EXCLUDED.last_active_at,
        public_signal_count = wire_active_actors.public_signal_count + 1,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  private func isActiveActor(hash: String, asOf: Date) async throws -> Bool {
    let rows = try await pool.query(
      "SELECT EXISTS(SELECT 1 FROM wire_active_actors WHERE actor_key_hash = \(hash) AND expires_at > \(asOf))",
      logger: logger
    )
    for try await row in rows { return try row.decode(Bool.self) }
    return false
  }

  private func insertSignal(
    event: InboxEvent,
    canonicalKey: String,
    actorHash: String,
    sourceURI: String,
    kind: String,
    asOf: Date
  ) async throws {
    let eventKey = "\(event.environment):\(event.sourceGeneration):\(event.sequence)"
    let transportEventKey = Self.transportEventKey(
      environment: event.environment,
      sourceHost: event.sourceHost,
      cursorKind: event.cursorKind,
      sequence: event.sequence
    )
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(sourceURI), 0))",
        logger: logger
      )
      try await connection.query(
        "SELECT ensure_wire_signal_event_partition((\(event.eventTime) AT TIME ZONE 'UTC')::date)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(sourceURI) AND occurred_at <= \(event.eventTime)",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_signal_events
          (event_key, transport_event_key, canonical_key, signal_kind, actor_key_hash, source_uri,
           occurred_at, expires_at)
        SELECT
          \(eventKey), \(transportEventKey), \(canonicalKey), \(kind), \(actorHash), \(sourceURI),
          \(event.eventTime), \(event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention))
        WHERE NOT EXISTS (
          SELECT 1 FROM wire_signal_events
          WHERE source_uri = \(sourceURI) AND occurred_at > \(event.eventTime)
        )
        ON CONFLICT DO NOTHING
        """,
        logger: logger
      )
    }
  }

  static func transportEventKey(
    environment: String,
    sourceHost: String,
    cursorKind: String,
    sequence: Int64
  ) -> String {
    "transport:\(environment):\(sourceHost):\(cursorKind):\(sequence)"
  }

  private func refreshRollups(asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtext('wire_signal_rollups_refresh')::bigint)",
        logger: logger
      )
      try await connection.query(
        "TRUNCATE TABLE wire_signal_rollups",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_signal_rollups
          (canonical_key, distinct_actors_1h, distinct_actors_24h, distinct_actors_7d,
           signals_1h, signals_24h, signals_7d, communities_24h,
           primary_community_key_hash, recommendations_24h,
           positive_feedback_24h, negative_feedback_24h,
           shares_1h, shares_24h, distinct_likers_24h, likes_1h, likes_24h,
           distinct_reposters_24h, reposts_1h, reposts_24h, updated_at)
        SELECT canonical_key,
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash),
          COUNT(*) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(*) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(*),
          COUNT(DISTINCT community_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400)) AND community_key_hash IS NOT NULL),
          MODE() WITHIN GROUP (ORDER BY community_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400)) AND community_key_hash IS NOT NULL),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'recommendation'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
            WHERE feedback.canonical_key = wire_signal_events.canonical_key
              AND feedback.feedback_value = 'good'
              AND feedback.occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND feedback.expires_at > \(asOf)), 0),
          COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
            WHERE feedback.canonical_key = wire_signal_events.canonical_key
              AND feedback.feedback_value = 'not_good'
              AND feedback.occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND feedback.expires_at > \(asOf)), 0),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          \(asOf)
        FROM wire_signal_events
        WHERE occurred_at >= \(asOf.addingTimeInterval(-7 * 86_400)) AND expires_at > \(asOf)
        GROUP BY canonical_key
        """,
        logger: logger
      )
    }
  }

  private func pruneActiveGraph(asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        DELETE FROM wire_active_actors actor
        WHERE actor.expires_at <= \(asOf)
          OR actor.actor_key_hash IN (
            SELECT actor_key_hash FROM wire_active_actors
            WHERE expires_at > \(asOf)
            ORDER BY last_active_at DESC, actor_key_hash
            OFFSET \(WireDataPolicy.maximumActiveActors)
          )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_follow_edges edge
        WHERE edge.expires_at <= \(asOf)
          OR NOT EXISTS (
            SELECT 1 FROM wire_active_actors actor
            WHERE actor.actor_key_hash = edge.follower_key_hash)
          OR NOT EXISTS (
            SELECT 1 FROM wire_active_actors actor
            WHERE actor.actor_key_hash = edge.followee_key_hash)
        """,
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_article_feedback WHERE expires_at <= \(asOf)",
        logger: logger
      )
    }
  }

  private func refreshCommunitiesIfNeeded(asOf: Date) async throws {
    let rows = try await pool.query(
      "SELECT MAX(assigned_at) FROM wire_actor_communities",
      logger: logger
    )
    var lastAssigned: Date?
    for try await row in rows { lastAssigned = try row.decode(Date?.self) }
    if let lastAssigned,
      asOf.timeIntervalSince(lastAssigned) < WireDataPolicy.clusteringCadence
    {
      return
    }

    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        CREATE TEMP TABLE wire_cluster_work (
          actor_key_hash TEXT PRIMARY KEY,
          label TEXT NOT NULL
        ) ON COMMIT DROP
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_cluster_work (actor_key_hash, label)
        SELECT actor_key_hash, actor_key_hash
        FROM wire_active_actors
        WHERE expires_at > \(asOf)
        """,
        logger: logger
      )
      for _ in 0..<6 {
        try await connection.query(
          """
          UPDATE wire_cluster_work current
          SET label = LEAST(current.label, neighbor.minimum_label)
          FROM (
            SELECT actor_key_hash, MIN(label) AS minimum_label
            FROM (
              SELECT edge.follower_key_hash AS actor_key_hash, target.label
              FROM wire_follow_edges edge
              JOIN wire_cluster_work target ON target.actor_key_hash = edge.followee_key_hash
              UNION ALL
              SELECT edge.followee_key_hash AS actor_key_hash, source.label
              FROM wire_follow_edges edge
              JOIN wire_cluster_work source ON source.actor_key_hash = edge.follower_key_hash
            ) adjacent
            GROUP BY actor_key_hash
          ) neighbor
          WHERE current.actor_key_hash = neighbor.actor_key_hash
          """,
          logger: logger
        )
      }
      try await connection.query("DELETE FROM wire_actor_communities", logger: logger)
      try await connection.query(
        """
        INSERT INTO wire_actor_communities
          (actor_key_hash, community_key_hash, algorithm_version, assigned_at, expires_at)
        SELECT work.actor_key_hash, work.label, 'wire-community-v1', \(asOf),
               \(asOf.addingTimeInterval(WireDataPolicy.communityAssignmentRetention))
        FROM wire_cluster_work work
        JOIN (
          SELECT label FROM wire_cluster_work GROUP BY label HAVING COUNT(*) >= 3
        ) qualifying ON qualifying.label = work.label
        """,
        logger: logger
      )
      try await connection.query(
        """
        UPDATE wire_signal_events signal
        SET community_key_hash = community.community_key_hash
        FROM wire_actor_communities community
        WHERE community.actor_key_hash = signal.actor_key_hash
        """,
        logger: logger
      )
      try await connection.query(
        """
        UPDATE wire_signal_events signal
        SET community_key_hash = NULL
        WHERE NOT EXISTS (
          SELECT 1 FROM wire_actor_communities community
          WHERE community.actor_key_hash = signal.actor_key_hash)
        """,
        logger: logger
      )
    }
  }

  private func finish(
    _ event: InboxEvent,
    status: String,
    retryAt: Date,
    reason: String?,
    asOf: Date
  ) async throws {
    let appliedAt: Date? = status == "applied" ? asOf : nil
    let deadAt: Date? = status == "dead_letter" ? asOf : nil
    let expiresAt =
      status == "applied"
      ? asOf.addingTimeInterval(300)
      : status == "dead_letter" ? asOf.addingTimeInterval(7 * 24 * 3_600) : .distantFuture
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox
      SET status = \(status), next_attempt_at = \(retryAt), failure_category = \(reason),
          failure_reason = \(reason), applied_at = \(appliedAt), dead_lettered_at = \(deadAt),
          lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
          expires_at = \(expiresAt), updated_at = \(asOf)
      WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
        AND seq = \(event.sequence) AND lease_token = \(event.leaseToken)
      """,
      logger: logger
    )
  }

  private static func firstString(_ value: Any, keys: [String]) -> String? {
    if let dictionary = value as? [String: Any] {
      for key in keys {
        if let string = dictionary[key] as? String, !string.isEmpty { return string }
        if let strings = dictionary[key] as? [String], let first = strings.first { return first }
      }
      for child in dictionary.values {
        if let result = firstString(child, keys: keys) { return result }
      }
    } else if let array = value as? [Any] {
      for child in array {
        if let result = firstString(child, keys: keys) { return result }
      }
    }
    return nil
  }

  private static func externalURL(_ record: [String: Any]) -> String? {
    let candidates = allStrings(record, keys: ["uri", "url"])
    return candidates.first { value in
      guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
        return false
      }
      return (scheme == "http" || scheme == "https") && url.host != nil
    }
  }

  private static func homepageURL(for articleURL: String) -> String? {
    guard let url = URL(string: articleURL), let scheme = url.scheme, let host = url.host else {
      return nil
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    return components.url?.absoluteString
  }

  private static func allStrings(_ value: Any, keys: Set<String>) -> [String] {
    var result: [String] = []
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        if keys.contains(key), let string = child as? String { result.append(string) }
        result.append(contentsOf: allStrings(child, keys: keys))
      }
    } else if let array = value as? [Any] {
      for child in array { result.append(contentsOf: allStrings(child, keys: keys)) }
    }
    return result
  }

  private static func containsQuote(_ record: [String: Any]) -> Bool {
    guard let type = firstString(record["embed"] as Any, keys: ["$type"]) else { return false }
    return type.contains("record")
  }

  private static func primaryLanguage(_ raw: String?) -> String {
    guard let raw else { return "und" }
    let value = raw.lowercased().split(separator: "-").first.map(String.init) ?? "und"
    return value.count >= 2 && value.count <= 8 ? value : "und"
  }

  private static func date(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    return ISO8601DateFormatter().date(from: raw)
  }
}
