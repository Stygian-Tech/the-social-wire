import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWireInboxProcessor: Sendable {
  private typealias InboxEvent = WireInboxEvent

  private enum ApplyError: Error {
    case unresolvedReference
    case unresolvedPublication
    case malformed
  }

  let pool: PostgresClient
  let logger: Logger
  let actorHasher: WireActorHasher
  let publicationResolver: any WirePublicationResolving
  let blobURLResolver: (any WireBlobURLResolving)?
  let linkMetadataStore: any WireLinkMetadataStoring
  let mentionStore: any WireTalkedAccountMentionStoring
  let batchSize: Int
  let maximumConcurrentEvents: Int
  let sourceScope: WireInboxSourceScope?
  let deferredRecommendationsEnabled: Bool
  let dependencyVerificationEnabled: Bool

  init(
    pool: PostgresClient,
    logger: Logger,
    actorSecret: String,
    publicationResolver: (any WirePublicationResolving)? = nil,
    blobURLResolver: (any WireBlobURLResolving)? = nil,
    linkMetadataStore: (any WireLinkMetadataStoring)? = nil,
    mentionStore: (any WireTalkedAccountMentionStoring)? = nil,
    batchSize: Int = 1_000,
    maximumConcurrentEvents: Int = 16,
    sourceScope: WireInboxSourceScope? = nil,
    deferredRecommendationsEnabled: Bool = false,
    dependencyVerificationEnabled: Bool = false
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
    self.blobURLResolver = blobURLResolver
    self.linkMetadataStore =
      linkMetadataStore ?? PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    self.mentionStore =
      mentionStore ?? PostgresWireTalkedAccountMentionStore(pool: pool, logger: logger)
    self.batchSize = max(1, min(batchSize, 5_000))
    self.maximumConcurrentEvents = max(1, min(maximumConcurrentEvents, 64))
    self.sourceScope = sourceScope
    self.deferredRecommendationsEnabled = deferredRecommendationsEnabled
    self.dependencyVerificationEnabled = dependencyVerificationEnabled
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
      && collection != WireExternalSignalCollection.marginLike
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
        WITH candidates AS (
          SELECT candidate.environment, candidate.source_generation, candidate.seq
          FROM wire_ingestion_inbox candidate
          WHERE candidate.environment = \(sourceScope.environment)
            AND candidate.source_generation = ANY(\(sourceScope.sourceGenerations))
            AND candidate.status IN ('pending', 'retry')
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
          ORDER BY candidate.next_attempt_at, candidate.seq, candidate.source_generation
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
        SELECT COALESCE(SUM(actionable_count), 0)::bigint, MIN(oldest_staged_at)
        FROM (
          SELECT COUNT(*)::bigint AS actionable_count,
                 MIN(staged_at) AS oldest_staged_at
          FROM wire_ingestion_inbox
          WHERE environment = \(sourceScope.environment)
            AND source_generation = ANY(\(sourceScope.sourceGenerations))
            AND status IN ('pending', 'retry') AND next_attempt_at <= \(asOf)
          UNION ALL
          SELECT COUNT(*)::bigint AS actionable_count,
                 MIN(staged_at) AS oldest_staged_at
          FROM wire_ingestion_inbox
          WHERE environment = \(sourceScope.environment)
            AND source_generation = ANY(\(sourceScope.sourceGenerations))
            AND status = 'leased' AND lease_expires_at <= \(asOf)
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

  func maintainGraph(asOf: Date) async throws -> Date {
    try await refreshCommunitiesIfNeeded(asOf: asOf)
  }

  func maintain(asOf: Date) async throws {
    try await mentionStore.pruneExpired(asOf: asOf)
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
          WHERE (status IN ('applied', 'dead_letter') OR (
            status IN ('deferred', 'superseded') AND EXISTS (
              SELECT 1 FROM wire_recommendation_journal journal
              WHERE journal.environment = wire_ingestion_inbox.environment
                AND journal.source_generation = wire_ingestion_inbox.source_generation
                AND journal.seq = wire_ingestion_inbox.seq
            ))) AND expires_at <= \(asOf)
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
            AND (status IN ('applied', 'dead_letter') OR (
            status IN ('deferred', 'superseded') AND EXISTS (
              SELECT 1 FROM wire_recommendation_journal journal
              WHERE journal.environment = wire_ingestion_inbox.environment
                AND journal.source_generation = wire_ingestion_inbox.source_generation
                AND journal.seq = wire_ingestion_inbox.seq
            ))) AND expires_at <= \(asOf)
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
    try await applyClaimed(event, asOf: asOf) == .applied
  }

  func applyClaimed(_ event: WireInboxEvent, asOf: Date) async throws -> WireInboxEventOutcome {
    try Task.checkCancellation()
    do {
      if event.eventKind == "snapshot" || event.cursorKind == "pds_record_snapshot"
        || (event.eventKind == "commit" && ["site.standard.document", "site.standard.entry", "site.standard.publication"].contains(event.collection ?? ""))
      {
        return try await applyStandardRecord(event, asOf: asOf)
      }
      if event.eventKind == "commit",
        event.collection == "site.standard.graph.recommend"
      {
        return try await PostgresWireRecommendationJournal(pool: pool, logger: logger, dependencyVerificationEnabled: dependencyVerificationEnabled)
          .process(event: event, actorHasher: actorHasher, asOf: asOf,
            deferUnresolved: deferredRecommendationsEnabled)
      }
      try await apply(event, asOf: asOf)
      try Task.checkCancellation()
      return try await finish(event, status: "applied", retryAt: asOf, reason: nil, asOf: asOf)
        ? .applied : .leaseLost
    } catch is CancellationError {
      throw CancellationError()
    } catch ApplyError.unresolvedReference {
      if asOf.timeIntervalSince(event.eventTime) < 24 * 3_600 {
        return try await finish(
          event,
          status: "retry",
          retryAt: asOf.addingTimeInterval(30),
          reason: "unresolved_subject",
          asOf: asOf
        ) ? .retry : .leaseLost
      } else {
        return try await finish(
          event,
          status: "dead_letter",
          retryAt: asOf,
          reason: "unresolved_subject_expired",
          asOf: asOf
        ) ? .terminal : .leaseLost
      }
    } catch ApplyError.unresolvedPublication {
      if asOf.timeIntervalSince(event.eventTime) < 24 * 3_600 {
        return try await finish(
          event,
          status: "retry",
          retryAt: asOf.addingTimeInterval(
            Self.publicationRetryDelay(attemptCount: event.attemptCount)),
          reason: "unresolved_publication",
          asOf: asOf
        ) ? .retry : .leaseLost
      } else {
        return try await finish(
          event,
          status: "dead_letter",
          retryAt: asOf,
          reason: "unresolved_publication_expired",
          asOf: asOf
        ) ? .terminal : .leaseLost
      }
    } catch ApplyError.malformed {
      return try await finish(
        event,
        status: "dead_letter",
        retryAt: asOf,
        reason: "malformed_event",
        asOf: asOf
      ) ? .terminal : .leaseLost
    } catch {
      try Task.checkCancellation()
      let terminal = event.attemptCount >= 8
      return try await finish(
        event,
        status: terminal ? "dead_letter" : "retry",
        retryAt: terminal ? asOf : asOf.addingTimeInterval(60),
        reason: String(reflecting: error).prefix(500).description,
        asOf: asOf
      ) ? (terminal ? .terminal : .retry) : .leaseLost
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
    // Read repository heads in one FIFO index pass. An anti-join over every
    // queued follower becomes quadratic when a few repositories have deep queues.
    // Project index columns only; fetch readiness from the handful of head rows.
    // Filter readiness after finding the head so future retries and live leases
    // remain barriers, and lock the actual inbox rows before claiming them.
    let rows = try await pool.query(
      """
      WITH repository_heads AS MATERIALIZED (
        SELECT DISTINCT ON (candidate.environment, candidate.source_generation, candidate.repo_did)
               candidate.environment, candidate.source_generation, candidate.repo_did,
               candidate.seq
        FROM wire_ingestion_inbox candidate
        WHERE candidate.status IN ('pending', 'leased', 'retry')
        ORDER BY candidate.environment, candidate.source_generation,
                 candidate.repo_did, candidate.seq
      ),
      candidates AS (
        SELECT candidate.environment, candidate.source_generation, candidate.seq,
               CASE WHEN candidate.status = 'leased' THEN candidate.lease_expires_at
                    ELSE candidate.next_attempt_at END AS eligible_at
        FROM repository_heads head
        JOIN wire_ingestion_inbox candidate
          ON candidate.environment = head.environment
          AND candidate.source_generation = head.source_generation
          AND candidate.seq = head.seq
        WHERE (candidate.status IN ('pending', 'retry') AND candidate.next_attempt_at <= \(asOf))
          OR (candidate.status = 'leased' AND candidate.lease_expires_at <= \(asOf))
        ORDER BY eligible_at, candidate.seq, candidate.environment, candidate.source_generation
        FOR UPDATE OF candidate SKIP LOCKED
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

  func claimScopedPassiveDeletes(asOf: Date, limit: Int? = nil) async throws -> [WireInboxEvent] {
    guard let sourceScope else { return [] }
    let token = UUID().uuidString.lowercased()
    let leaseUntil = asOf.addingTimeInterval(120)
    let claimLimit = Self.boundedClaimLimit(
      batchSize: batchSize,
      maximumConcurrentEvents: min(maximumConcurrentEvents, limit ?? maximumConcurrentEvents)
    )
    let rows = try await pool.query(
      """
      WITH pending_retry_candidates AS (
        SELECT candidate.environment, candidate.source_generation, candidate.seq,
               candidate.next_attempt_at AS eligible_at
        FROM wire_ingestion_inbox candidate
        WHERE candidate.environment = \(sourceScope.environment)
          AND candidate.source_generation = ANY(\(sourceScope.sourceGenerations))
          AND candidate.status IN ('pending', 'retry')
          AND candidate.next_attempt_at <= \(asOf)
          AND candidate.event_kind = 'commit'
          AND candidate.collection IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
          AND candidate.operation = 'delete'
          AND candidate.record_key IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM wire_ingestion_inbox earlier
            WHERE earlier.environment = candidate.environment
              AND earlier.source_generation = candidate.source_generation
              AND earlier.repo_did = candidate.repo_did
              AND earlier.seq < candidate.seq
              AND earlier.status IN ('pending', 'leased', 'retry')
              AND (earlier.event_kind <> 'commit'
                OR earlier.collection IS NULL
                OR earlier.collection NOT IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
                OR earlier.operation IS DISTINCT FROM 'delete'
                OR earlier.record_key IS NULL)
          )
        ORDER BY candidate.next_attempt_at, candidate.seq
        FOR UPDATE SKIP LOCKED
        LIMIT \(claimLimit)
      ),
      expired_lease_candidates AS (
        SELECT candidate.environment, candidate.source_generation, candidate.seq,
               candidate.lease_expires_at AS eligible_at
        FROM wire_ingestion_inbox candidate
        WHERE candidate.environment = \(sourceScope.environment)
          AND candidate.source_generation = ANY(\(sourceScope.sourceGenerations))
          AND candidate.status = 'leased'
          AND candidate.lease_expires_at <= \(asOf)
          AND candidate.event_kind = 'commit'
          AND candidate.collection IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
          AND candidate.operation = 'delete'
          AND candidate.record_key IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM wire_ingestion_inbox earlier
            WHERE earlier.environment = candidate.environment
              AND earlier.source_generation = candidate.source_generation
              AND earlier.repo_did = candidate.repo_did
              AND earlier.seq < candidate.seq
              AND earlier.status IN ('pending', 'leased', 'retry')
              AND (earlier.event_kind <> 'commit'
                OR earlier.collection IS NULL
                OR earlier.collection NOT IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
                OR earlier.operation IS DISTINCT FROM 'delete'
                OR earlier.record_key IS NULL)
          )
        ORDER BY candidate.lease_expires_at, candidate.seq
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
    // Keep the same repository-head scan as the global claim, restricted to
    // this drain's environment and source generations in the FIFO index.
    let rows = try await pool.query(
      """
      WITH repository_heads AS MATERIALIZED (
        SELECT DISTINCT ON (candidate.environment, candidate.source_generation, candidate.repo_did)
               candidate.environment, candidate.source_generation, candidate.repo_did,
               candidate.seq
        FROM wire_ingestion_inbox candidate
        WHERE candidate.environment = \(sourceScope.environment)
          AND candidate.source_generation = ANY(\(sourceScope.sourceGenerations))
          AND candidate.status IN ('pending', 'leased', 'retry')
        ORDER BY candidate.environment, candidate.source_generation,
                 candidate.repo_did, candidate.seq
      ),
      candidates AS (
        SELECT candidate.environment, candidate.source_generation, candidate.seq,
               CASE WHEN candidate.status = 'leased' THEN candidate.lease_expires_at
                    ELSE candidate.next_attempt_at END AS eligible_at
        FROM repository_heads head
        JOIN wire_ingestion_inbox candidate
          ON candidate.environment = head.environment
          AND candidate.source_generation = head.source_generation
          AND candidate.seq = head.seq
        WHERE (candidate.status IN ('pending', 'retry') AND candidate.next_attempt_at <= \(asOf))
          OR (candidate.status = 'leased' AND candidate.lease_expires_at <= \(asOf))
        ORDER BY eligible_at, candidate.seq, candidate.environment, candidate.source_generation
        FOR UPDATE OF candidate SKIP LOCKED
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
    case let collection where WireExternalSignalCollection.supported.contains(collection):
      try await applyExternalSignalRecord(
        collection: collection,
        record: record,
        event: event,
        sourceURI: sourceURI,
        asOf: asOf
      )
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

  /// PDS observations hydrate discovery without inventing publication activity.
  /// Live mutations share the durable version fence, including deletion tombstones.
  private func applyStandardRecord(_ event: InboxEvent, asOf: Date) async throws -> WireInboxEventOutcome {
    let record = try standardRecord(event)
    guard let version = try await standardRecordLease(event, asOf: asOf) else { return .leaseLost }
    let candidate = PostgresWireStandardRecordFence(event: event, revision: version.0, cid: version.1)
    let existing = try await pool.withConnection { connection in
      try await PostgresWireStandardRecordFence.load(event: event, on: connection, logger: logger)
    }
    let preflightOrder = existing.map { candidate.compared(to: $0) } ?? .newer
    let resolved: WireResolvedStandardSiteDocument?
    let thumbnail: String?
    if event.collection == "site.standard.publication" || preflightOrder == .older || preflightOrder == .conflict {
      resolved = nil
      thumbnail = nil
    } else if let record {
      // All publication and image resolution happens before reserving the
      // transaction connection, including when the pool has only one slot.
      resolved = try await resolveArticle(record: record, asOf: asOf)
      thumbnail = try await WireStandardSiteRecordImage.resolveURL(
        from: record, repoDID: event.repoDID, blobURLResolver: blobURLResolver)
    } else {
      resolved = nil
      thumbnail = nil
    }
    let publicationURI = event.collection == "site.standard.publication" ? event.sourceURI : nil
    if let publicationURI { await publicationResolver.invalidate(publicationURI: publicationURI) }
    let outcome: WireInboxEventOutcome
    do {
      outcome = try await pool.withTransaction(logger: logger) { connection in
      guard let version = try await standardRecordLease(event, asOf: asOf, connection: connection) else {
        return .leaseLost
      }
      guard let sourceURI = event.sourceURI else { throw ApplyError.malformed }
      // Same order as the recommendation/account path: inbox, account, source.
      let accountLock = "wire-recommendation-account:\(event.environment):\(event.repoDID)"
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(accountLock), 0))", logger: logger)
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(sourceURI), 0))", logger: logger)
      let candidate = PostgresWireStandardRecordFence(event: event, revision: version.0, cid: version.1)
      let previous = try await PostgresWireStandardRecordFence.load(event: event, on: connection, logger: logger)
      let order = previous.map { candidate.compared(to: $0) } ?? .newer
      switch order {
      case .older:
        return try await finish(event, status: "dead_letter", retryAt: asOf,
          reason: "standard_record_superseded", asOf: asOf, connection: connection) ? .terminal : .leaseLost
      case .conflict:
        // Unknown clocks retain the original payload for explicit reconciliation.
        return try await finish(event, status: "retry", retryAt: asOf.addingTimeInterval(300),
          reason: "standard_record_order_conflict", asOf: asOf, connection: connection) ? .retry : .leaseLost
      case .newer, .same: break
      }
      if event.collection != "site.standard.publication", event.operation != "delete",
        preflightOrder == .older || preflightOrder == .conflict
      {
        // Another worker may reconcile a previously incomparable fence while
        // preflight runs. Resolve metadata on the next attempt, never publish an
        // accepted record whose expensive resolution was deliberately skipped.
        return try await finish(event, status: "retry", retryAt: asOf.addingTimeInterval(1),
          reason: "standard_record_resolve_again", asOf: asOf, connection: connection) ? .retry : .leaseLost
      }
      let effectiveEventTime = order == .same
        ? min(event.eventTime, previous?.time ?? event.eventTime) : event.eventTime
      let accountRows = try await connection.query(
        """
        SELECT active, inactive_through FROM wire_recommendation_account_fences
        WHERE environment = \(event.environment) AND repo_did = \(event.repoDID)
        """, logger: logger)
      for try await row in accountRows {
        let account = try row.decode((Bool, Date?).self)
        if event.operation != "delete", !account.0 || account.1.map({ effectiveEventTime <= $0 }) == true {
          let reason = event.eventKind == "snapshot" ? "snapshot_account_inactive" : "standard_record_account_inactive"
          return try await finish(event, status: "dead_letter", retryAt: asOf,
            reason: reason, asOf: asOf, connection: connection) ? .terminal : .leaseLost
        }
      }
      try Task.checkCancellation()
      let record = try standardRecord(event)
      let store = PostgresWirePublicationMetadataStore(pool: pool, logger: logger)
      let isSnapshot = event.eventKind == "snapshot"
      let hadActivity = order == .same && previous?.activityRecorded == true
      let activityEvent = hadActivity ? previous!.originalEvent(using: event) : event
      if event.operation == "delete" {
        if event.collection == "site.standard.publication" {
          try await store.remove(publicationURI: sourceURI, observedAt: event.eventTime, connection: connection, versionIsFenced: true)
        } else {
          try await retractStandardRecord(sourceURI: sourceURI, asOf: asOf, on: connection)
        }
      } else if event.collection == "site.standard.publication", let record {
        guard let metadata = WirePublicationMetadata.parse(
          publicationURI: sourceURI, repoDID: event.repoDID, record: record)
        else { throw ApplyError.malformed }
        try await store.upsert(metadata, asOf: event.eventTime, connection: connection, versionIsFenced: true)
      } else if let resolved, let record {
        try await applyArticle(record: record, event: activityEvent, sourceURI: sourceURI,
          asOf: asOf, resolvedDocument: resolved, projectionConnection: connection,
          resolvedThumbnail: thumbnail, recordsActivity: !isSnapshot,
          incrementsActorActivity: !hadActivity, refreshesSignalTime: !isSnapshot && !hadActivity,
          signalTime: order == .same && previous?.kind == "snapshot" ? event.eventTime : nil)
      }
      let recordsActivity = !isSnapshot && event.operation != "delete"
        && event.collection != "site.standard.publication" && resolved != nil
      // Replays keep the first real commit's transport and timestamp so an
      // unlogged signal repair cannot gain a later observed-at publication boost.
      let fence: PostgresWireStandardRecordFence
      if order == .same, let previous, previous.activityRecorded || !recordsActivity {
        fence = previous.observing(isSnapshot ? version.0 : nil)
      } else {
        fence = PostgresWireStandardRecordFence(event: event, revision: version.0, cid: version.1,
          activityRecorded: recordsActivity)
          .observing(order == .same ? previous?.observedRevision : nil)
      }
      try await fence.save(event: event, on: connection, asOf: asOf, logger: logger)
      try Task.checkCancellation()
      return try await finish(event, status: "applied", retryAt: asOf, reason: nil,
        asOf: asOf, connection: connection) ? .applied : .leaseLost
      }
    } catch {
      if let publicationURI { await publicationResolver.invalidate(publicationURI: publicationURI) }
      throw error
    }
    // withTransaction has committed (or rolled back) before invalidating. Doing
    // this inside its closure would let another replica refill pre-commit data.
    if let publicationURI { await publicationResolver.invalidate(publicationURI: publicationURI) }
    return outcome
  }

  private func standardRecord(_ event: InboxEvent) throws -> [String: Any]? {
    guard !Self.isPayloadNormalizationFailure(event.payloadJSON), let collection = event.collection,
      ["site.standard.document", "site.standard.entry", "site.standard.publication"].contains(collection),
      let key = event.recordKey, !key.isEmpty, !key.contains("/"),
      let document = try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any]
    else { throw ApplyError.malformed }
    if event.eventKind == "snapshot" || event.cursorKind == "pds_record_snapshot" {
      guard event.eventKind == "snapshot", event.cursorKind == "pds_record_snapshot", event.operation == "update",
        let snapshot = document["snapshot"] as? [String: Any],
        let cid = snapshot["cid"] as? String, !cid.isEmpty,
        let rev = snapshot["rev"] as? String, PostgresWireStandardRecordFence.validRevision(rev),
        let record = snapshot["record"] as? [String: Any], record["$type"] as? String == collection
      else { throw ApplyError.malformed }
      return record
    }
    guard event.eventKind == "commit", ["create", "update", "delete"].contains(event.operation ?? "")
    else { throw ApplyError.malformed }
    if event.operation == "delete" { return nil }
    guard let commit = document["commit"] as? [String: Any], let record = commit["record"] as? [String: Any],
      record["$type"] == nil || record["$type"] as? String == collection
    else { throw ApplyError.malformed }
    return record
  }

  /// Revalidate the complete claim and retained snapshot identity under its row
  /// lock. CID/revision come from the inbox, not caller-created claim metadata.
  private func standardRecordLease(
    _ event: InboxEvent, asOf: Date, connection: PostgresConnection? = nil
  ) async throws -> (String?, String?)? {
    var query: PostgresQuery = """
      SELECT repo_rev, record_cid,
        payload = \(event.payloadJSON)::jsonb
        AND event_kind = \(event.eventKind) AND cursor_kind = \(event.cursorKind)
        AND operation = \(event.operation) AND collection = \(event.collection)
        AND repo_did = \(event.repoDID) AND record_key = \(event.recordKey)
        AND source_host = \(event.sourceHost) AND event_time = \(event.eventTime)
        AND (event_kind <> 'snapshot' OR (record_cid IS NOT NULL AND repo_rev IS NOT NULL
          AND record_cid = payload #>> '{snapshot,cid}' AND repo_rev = payload #>> '{snapshot,rev}'))
      FROM wire_ingestion_inbox
      WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
        AND seq = \(event.sequence) AND status = 'leased' AND lease_token = \(event.leaseToken)
        AND lease_expires_at > \(asOf)
      """
    if connection != nil { query.sql += " FOR UPDATE" }
    for try await row in try await projectionQuery(query, on: connection) {
      let value = try row.decode((String?, String?, Bool?).self)
      guard value.2 == true else { throw ApplyError.malformed }
      return (value.0, value.1)
    }
    return nil
  }

  private func retractStandardRecord(sourceURI: String, asOf: Date, on connection: PostgresConnection) async throws {
    // Revision ordering has already rejected stale deletes. A snapshot's newer
    // observation time must not protect its aliases from an authoritative delete.
    try await connection.query("DELETE FROM wire_signal_events WHERE source_uri = \(sourceURI)", logger: logger)
    try await connection.query("DELETE FROM wire_item_aliases WHERE alias_key = \(sourceURI)", logger: logger)
    try await connection.query(
      "UPDATE wire_items SET updated_at = \(asOf) WHERE representative_uri = \(sourceURI)", logger: logger)
  }

  @discardableResult
  private func projectionQuery(_ query: PostgresQuery, on connection: PostgresConnection?)
    async throws -> PostgresRowSequence
  {
    if let connection { return try await connection.query(query, logger: logger) }
    return try await pool.query(query, logger: logger)
  }

  private func resolveArticle(record: [String: Any], asOf: Date) async throws
    -> WireResolvedStandardSiteDocument?
  {
    do {
      return try await WireStandardSiteDocumentResolver.resolve(
        record: record, publicationResolver: publicationResolver, asOf: asOf)
    } catch WireStandardSiteDocumentError.unaddressableDocument {
      return nil
    } catch WireStandardSiteDocumentError.unresolvedPublication {
      throw ApplyError.unresolvedPublication
    } catch WireStandardSiteDocumentError.malformedDocument,
      WireStandardSiteDocumentError.invalidPublication
    {
      throw ApplyError.malformed
    }
  }

  private func applyArticle(
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date,
    resolvedDocument: WireResolvedStandardSiteDocument? = nil,
    projectionConnection: PostgresConnection? = nil,
    resolvedThumbnail: String? = nil,
    recordsActivity: Bool = true,
    incrementsActorActivity: Bool = true,
    refreshesSignalTime: Bool = true,
    signalTime: Date? = nil
  ) async throws {
    let resolved: WireResolvedStandardSiteDocument
    if let resolvedDocument {
      resolved = resolvedDocument
    } else {
      guard let document = try await resolveArticle(record: record, asOf: asOf) else { return }
      resolved = document
    }
    guard let identity = WireCanonicalizer.canonicalize(resolved.canonicalURL),
      let host = URL(string: identity.canonicalURL)?.host
    else { throw ApplyError.malformed }
    let targetKind = WireContentQualityClassifier.targetKind(
      for: identity.canonicalURL, standardSite: true)
    guard targetKind.canCreateItem else { return }
    let title = Self.firstString(record, keys: ["title", "name"]) ?? host
    let summary = Self.firstString(record, keys: ["summary", "description", "text", "textContent"])
    let thumbnail: String?
    if projectionConnection != nil {
      thumbnail = resolvedThumbnail
    } else {
      thumbnail = try await WireStandardSiteRecordImage.resolveURL(
        from: record, repoDID: event.repoDID, blobURLResolver: blobURLResolver)
    }
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
      asOf: asOf,
      connection: projectionConnection,
      recordsActivity: refreshesSignalTime,
      signalTime: signalTime
    )
    try await upsertAlias(
      alias: sourceURI, type: "at_uri", canonicalKey: identity.canonicalKey, asOf: asOf, connection: projectionConnection)
    try await upsertAlias(
      alias: identity.canonicalURL, type: "url", canonicalKey: identity.canonicalKey, asOf: asOf, connection: projectionConnection)
    guard recordsActivity,
      (incrementsActorActivity && signalTime == nil)
        || event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention) > asOf
    else { return }
    try await upsertActor(hash: actorHash, asOf: incrementsActorActivity ? (signalTime ?? asOf) : event.eventTime,
      connection: projectionConnection, incrementsActivity: incrementsActorActivity)
    // Recovery must still project the corpus and record its version/activity
    // fence, but an expired signal cannot contribute to any ranking window.
    // Avoid rebuilding throwaway partitions and rows for that replay history.
    guard event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention) > asOf else { return }
    try await insertSignal(
      event: event,
      canonicalKey: identity.canonicalKey,
      actorHash: actorHash,
      sourceURI: sourceURI,
      kind: "publication",
      asOf: asOf,
      connection: projectionConnection
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
      language: "und",
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
    guard
      let subjectURI = Self.referenceSubjectURI(
        record: record,
        collection: event.collection
      )
    else { throw ApplyError.malformed }
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

  private func applyExternalSignalRecord(
    collection: String,
    record: [String: Any],
    event: InboxEvent,
    sourceURI: String,
    asOf: Date
  ) async throws {
    let normalized: WireExternalSignalRecord?
    do {
      normalized = try WireExternalSignalRecordNormalizer.normalize(
        collection: collection,
        record: record
      )
    } catch WireExternalSignalRecordError.malformed {
      throw ApplyError.malformed
    }
    guard let normalized else {
      if event.operation == "update" {
        try await retract(sourceURI: sourceURI, eventTime: event.eventTime, asOf: asOf)
      }
      return
    }

    switch normalized.action {
    case .retractRecord(let targetSourceURI):
      try await retract(sourceURI: targetSourceURI, eventTime: event.eventTime, asOf: asOf)
    case .replaceSignals(let kind, let targets):
      var canonicalKeys: [String] = []
      for target in targets {
        let resolvedCanonicalKey: String?
        switch target {
        case .url(let rawURL):
          resolvedCanonicalKey = try await ensureExternalSignalItem(
            rawURL: rawURL,
            record: record,
            sourceURI: sourceURI,
            asOf: asOf
          )
        case .reference(let reference):
          resolvedCanonicalKey = try await canonicalKey(alias: reference)
        }
        guard let resolvedCanonicalKey else {
          if Self.retriesUnresolvedReference(collection: collection) {
            throw ApplyError.unresolvedReference
          }
          continue
        }
        if !canonicalKeys.contains(resolvedCanonicalKey) {
          canonicalKeys.append(resolvedCanonicalKey)
        }
      }

      let actorHash = try actorHasher.hash(event.repoDID)
      if !canonicalKeys.isEmpty {
        try await upsertActor(hash: actorHash, asOf: asOf)
        for canonicalKey in canonicalKeys {
          try await appendProvenance(kind, canonicalKey: canonicalKey, asOf: asOf)
        }
      }
      try await replaceSignals(
        event: event,
        canonicalKeys: canonicalKeys,
        actorHash: actorHash,
        sourceURI: sourceURI,
        kind: kind,
        sourceCollection: normalized.sourceCollection,
        sourceAction: normalized.sourceAction,
        asOf: asOf
      )
      if normalized.aliasesSourceRecord, let canonicalKey = canonicalKeys.first {
        try await upsertAlias(
          alias: sourceURI,
          type: "at_uri",
          canonicalKey: canonicalKey,
          asOf: asOf
        )
      }
    }
  }

  private func ensureExternalSignalItem(
    rawURL: String,
    record: [String: Any],
    sourceURI: String,
    asOf: Date
  ) async throws -> String? {
    let targetKind = WireContentQualityClassifier.targetKind(for: rawURL)
    guard targetKind.canCreateItem,
      let identity = WireCanonicalizer.canonicalize(rawURL),
      let host = URL(string: identity.canonicalURL)?.host
    else { return nil }

    let embedded = WireEmbeddedCardMetadata.extract(
      from: record,
      canonicalURL: identity.canonicalURL
    )
    let sourceText = Self.firstString(record, keys: ["text", "note", "description", "value"])
    let title =
      embedded?.title
      ?? Self.firstString(record, keys: ["title", "name"])
      ?? sourceText?.split(separator: "\n").first.map { String($0.prefix(200)) }
      ?? host
    let summary = embedded?.description ?? sourceText
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
      summary: summary,
      thumbnail: embedded?.imageURL,
      language: "und",
      publishedAt: Self.date(Self.firstString(record, keys: ["publishedAt", "createdAt"])),
      provenance: ["recommendation"],
      confidence: 0.6,
      presentationSource: embedded == nil ? "fallback" : "embedded_card",
      presentationPriority: embedded == nil ? 100 : 200,
      publicationHomepageURL: Self.homepageURL(for: identity.canonicalURL),
      publicationIconURL: embedded?.iconURL,
      sourceText: sourceText,
      targetKind: targetKind,
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
      alias: identity.canonicalURL,
      type: "url",
      canonicalKey: identity.canonicalKey,
      asOf: asOf
    )
    return identity.canonicalKey
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
      let active = account["active"] as? Bool
    else { return }
    let actorHash = try actorHasher.hash(event.repoDID)
    if !active { await publicationResolver.invalidateAccount(repoDID: event.repoDID) }
    let retracted: Bool
    do {
      retracted = try await pool.withTransaction(logger: logger) { connection in
      guard try await PostgresWireRecommendationJournal.observeAccount(
        event: event, on: connection, asOf: asOf)
      else { return false }
      guard !active else { return false }
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
      return true
      }
    } catch {
      if !active { await publicationResolver.invalidateAccount(repoDID: event.repoDID) }
      throw error
    }
    if !active { await publicationResolver.invalidateAccount(repoDID: event.repoDID) }
    if retracted {
      try await mentionStore.removeActor(did: event.repoDID, actorKeyHash: actorHash)
    }
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
    asOf: Date,
    connection: PostgresConnection? = nil,
    recordsActivity: Bool = true,
    signalTime: Date? = nil
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
    let isExplicitAdultContent = WireBaseContentSafetyClassifier.isExplicitAdultContent(
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
      "languageSource": presentationSource == "standard_site" && language != "und"
        ? "standard_site_record" : "unknown",
    ]
    if thumbnail != nil { presentation["thumbnailSource"] = presentationSource }
    presentation["homepageUrl"] = publicationHomepageURL
    presentation["iconUrl"] = publicationIconURL
    let presentationJSON = String(
      decoding: try JSONSerialization.data(withJSONObject: presentation),
      as: UTF8.self
    )
    let expiresAt = WireCacheExpiry.hourlyDeadline(asOf: asOf, retention: WireDataPolicy.itemRetention)
    let signalAt: Date? = recordsActivity ? (signalTime ?? asOf) : nil
    // Compare the effective merged row, including exact activity times. A skipped
    // update still seeds missing metadata from the existing item for cache recovery.
    try await projectionQuery(
      """
      WITH upserted_item AS (
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
         \(publishedAt), \(asOf), \(asOf), \(signalAt), \(confidence), \(targetKind.canCreateItem),
         \(targetKind.rawValue),
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
        language_code = CASE
          WHEN EXCLUDED.presentation_snapshot->>'metadataSource' = 'standard_site'
          THEN EXCLUDED.language_code
          ELSE wire_items.language_code END,
        topic_keys = CASE WHEN jsonb_array_length(wire_items.topic_keys) = 0
          THEN EXCLUDED.topic_keys ELSE wire_items.topic_keys END,
        provenance = (
          SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
          FROM (
            SELECT DISTINCT value
            FROM jsonb_array_elements_text(wire_items.provenance || EXCLUDED.provenance)
          ) unique_provenance
        ), target_kind = CASE
          WHEN wire_items.target_kind NOT IN ('external_article', 'standard_site_document')
            THEN wire_items.target_kind
          WHEN EXCLUDED.target_kind NOT IN ('external_article', 'standard_site_document')
            THEN EXCLUDED.target_kind
          WHEN wire_items.target_kind = 'standard_site_document' THEN wire_items.target_kind
          ELSE EXCLUDED.target_kind END,
        commercial_score = GREATEST(wire_items.commercial_score, EXCLUDED.commercial_score),
        commercial_class = CASE
          WHEN wire_items.commercial_score > EXCLUDED.commercial_score
          THEN wire_items.commercial_class ELSE EXCLUDED.commercial_class END,
        commercial_reasons = CASE
          WHEN wire_items.commercial_score > EXCLUDED.commercial_score
          THEN wire_items.commercial_reasons ELSE EXCLUDED.commercial_reasons END,
        published_at = COALESCE(wire_items.published_at, EXCLUDED.published_at),
        last_seen_at = EXCLUDED.last_seen_at,
        last_signal_at = COALESCE(EXCLUDED.last_signal_at, wire_items.last_signal_at),
        eligible = wire_items.eligible AND EXCLUDED.eligible,
        source_confidence = GREATEST(wire_items.source_confidence, EXCLUDED.source_confidence),
        expires_at = GREATEST(wire_items.expires_at, EXCLUDED.expires_at), updated_at = EXCLUDED.updated_at
      WHERE CASE
        -- Advancing observations already require an update; avoid merging JSON twice.
        WHEN wire_items.last_seen_at IS DISTINCT FROM EXCLUDED.last_seen_at
          OR wire_items.last_signal_at IS DISTINCT FROM
            COALESCE(EXCLUDED.last_signal_at, wire_items.last_signal_at)
          OR wire_items.expires_at IS DISTINCT FROM
            GREATEST(wire_items.expires_at, EXCLUDED.expires_at)
        THEN TRUE
        ELSE ROW(
        wire_items.canonical_url,
        wire_items.representative_uri,
        wire_items.publication_id,
        wire_items.author_key,
        wire_items.author_name,
        wire_items.source_name,
        wire_items.title,
        wire_items.summary,
        wire_items.thumbnail_url,
        wire_items.presentation_snapshot,
        wire_items.publication_homepage_url,
        wire_items.publication_icon_url,
        wire_items.language_code,
        wire_items.topic_keys,
        wire_items.provenance,
        wire_items.target_kind,
        wire_items.commercial_score,
        wire_items.commercial_class,
        wire_items.commercial_reasons,
        wire_items.published_at,
        wire_items.eligible,
        wire_items.source_confidence)
        IS DISTINCT FROM ROW(
        EXCLUDED.canonical_url,
        COALESCE(wire_items.representative_uri, EXCLUDED.representative_uri),
        COALESCE(wire_items.publication_id, EXCLUDED.publication_id),
        COALESCE(wire_items.author_key, EXCLUDED.author_key),
        COALESCE(wire_items.author_name, EXCLUDED.author_name),
        CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN EXCLUDED.source_name ELSE wire_items.source_name END,
        CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN EXCLUDED.title ELSE wire_items.title END,
        CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN COALESCE(EXCLUDED.summary, wire_items.summary) ELSE wire_items.summary END,
        CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN COALESCE(EXCLUDED.thumbnail_url, wire_items.thumbnail_url) ELSE wire_items.thumbnail_url END,
        CASE
          WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
            >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
          THEN EXCLUDED.presentation_snapshot ELSE wire_items.presentation_snapshot END,
        COALESCE(
          EXCLUDED.publication_homepage_url, wire_items.publication_homepage_url),
        COALESCE(
          EXCLUDED.publication_icon_url, wire_items.publication_icon_url),
        CASE
          WHEN EXCLUDED.presentation_snapshot->>'metadataSource' = 'standard_site'
          THEN EXCLUDED.language_code
          ELSE wire_items.language_code END,
        CASE WHEN jsonb_array_length(wire_items.topic_keys) = 0
          THEN EXCLUDED.topic_keys ELSE wire_items.topic_keys END,
        (
          SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
          FROM (
            SELECT DISTINCT value
            FROM jsonb_array_elements_text(wire_items.provenance || EXCLUDED.provenance)
          ) unique_provenance
        ),
        CASE
          WHEN wire_items.target_kind NOT IN ('external_article', 'standard_site_document')
            THEN wire_items.target_kind
          WHEN EXCLUDED.target_kind NOT IN ('external_article', 'standard_site_document')
            THEN EXCLUDED.target_kind
          WHEN wire_items.target_kind = 'standard_site_document' THEN wire_items.target_kind
          ELSE EXCLUDED.target_kind END,
        GREATEST(wire_items.commercial_score, EXCLUDED.commercial_score),
        CASE
          WHEN wire_items.commercial_score > EXCLUDED.commercial_score
          THEN wire_items.commercial_class ELSE EXCLUDED.commercial_class END,
        CASE
          WHEN wire_items.commercial_score > EXCLUDED.commercial_score
          THEN wire_items.commercial_reasons ELSE EXCLUDED.commercial_reasons END,
        COALESCE(wire_items.published_at, EXCLUDED.published_at),
        wire_items.eligible AND EXCLUDED.eligible,
        GREATEST(wire_items.source_confidence, EXCLUDED.source_confidence))
      END
      RETURNING canonical_key, canonical_url, eligible, expires_at
      )
      INSERT INTO wire_link_metadata_cache
        (canonical_key, canonical_url, source, status, retry_after, failure_count, updated_at)
      SELECT canonical_key, canonical_url, 'fallback', 'pending', \(asOf), 0, \(asOf)
      FROM (
        SELECT canonical_key, canonical_url, eligible, expires_at FROM upserted_item
        UNION ALL
        SELECT canonical_key, canonical_url, eligible, expires_at FROM wire_items
        WHERE canonical_key = \(identity.canonicalKey)
          AND NOT EXISTS (SELECT 1 FROM upserted_item)
      ) item
      WHERE eligible AND expires_at > \(asOf) AND canonical_url LIKE 'https://%'
        AND NOT EXISTS (
          SELECT 1 FROM wire_link_metadata_cache cache
          WHERE cache.canonical_key = item.canonical_key
        )
      ON CONFLICT (canonical_key) DO NOTHING
      """,
      on: connection
    )
    if isExplicitAdultContent {
      try await projectionQuery(
        """
        INSERT INTO wire_labels
          (canonical_key, label_key, label_value, source, confidence, applied_at, expires_at)
        VALUES
          (\(identity.canonicalKey), 'moderation', 'adult',
           \(WireBaseContentSafetyClassifier.labelSource), 1, \(asOf), \(expiresAt))
        ON CONFLICT (canonical_key, label_key, source) DO UPDATE SET
          label_value = EXCLUDED.label_value,
          confidence = EXCLUDED.confidence,
          applied_at = EXCLUDED.applied_at,
          expires_at = EXCLUDED.expires_at
        """,
        on: connection
      )
    }
  }

  private func upsertAlias(
    alias: String,
    type: String,
    canonicalKey: String,
    asOf: Date,
    connection: PostgresConnection? = nil
  ) async throws {
    try await projectionQuery(
      """
      INSERT INTO wire_item_aliases (alias_key, canonical_key, alias_type, expires_at)
      VALUES (\(alias), \(canonicalKey), \(type), \(WireCacheExpiry.hourlyDeadline(asOf: asOf, retention: WireDataPolicy.itemRetention)))
      ON CONFLICT (alias_key) DO UPDATE SET canonical_key = EXCLUDED.canonical_key,
        expires_at = GREATEST(wire_item_aliases.expires_at, EXCLUDED.expires_at)
      WHERE (wire_item_aliases.canonical_key, wire_item_aliases.expires_at)
        IS DISTINCT FROM (
          EXCLUDED.canonical_key, GREATEST(wire_item_aliases.expires_at, EXCLUDED.expires_at))
      """,
      on: connection
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
      WHERE canonical_key = \(canonicalKey) AND NOT (item.provenance ? \(kind))
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

  private func upsertActor(
    hash: String, asOf: Date, connection: PostgresConnection? = nil, incrementsActivity: Bool = true
  ) async throws {
    try await projectionQuery(
      """
      INSERT INTO wire_active_actors
        (actor_key_hash, first_active_at, last_active_at, public_signal_count, expires_at)
      VALUES (\(hash), \(asOf), \(asOf), 1, \(asOf.addingTimeInterval(WireDataPolicy.activeActorRetention)))
      ON CONFLICT (actor_key_hash) DO UPDATE SET last_active_at = GREATEST(wire_active_actors.last_active_at, EXCLUDED.last_active_at),
        public_signal_count = wire_active_actors.public_signal_count + 1,
        expires_at = GREATEST(wire_active_actors.expires_at, EXCLUDED.expires_at)
      WHERE \(incrementsActivity)
      """,
      on: connection
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
    asOf: Date,
    connection: PostgresConnection? = nil
  ) async throws {
    let eventKey = "\(event.environment):\(event.sourceGeneration):\(event.sequence)"
    let transportEventKey = Self.transportEventKey(
      environment: event.environment,
      sourceHost: event.sourceHost,
      cursorKind: event.cursorKind,
      sequence: event.sequence
    )
    if let connection {
      try await insertSignal(event: event, canonicalKey: canonicalKey, actorHash: actorHash,
        sourceURI: sourceURI, kind: kind, eventKey: eventKey, transportEventKey: transportEventKey,
        on: connection)
    } else {
      try await pool.withTransaction(logger: logger) { connection in
        try await insertSignal(event: event, canonicalKey: canonicalKey, actorHash: actorHash,
          sourceURI: sourceURI, kind: kind, eventKey: eventKey, transportEventKey: transportEventKey,
          on: connection)
      }
    }
  }

  private func insertSignal(
    event: InboxEvent, canonicalKey: String, actorHash: String, sourceURI: String,
    kind: String, eventKey: String, transportEventKey: String, on connection: PostgresConnection
  ) async throws {
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
         source_collection, source_action, occurred_at, expires_at)
      SELECT
        \(eventKey), \(transportEventKey), \(canonicalKey), \(kind), \(actorHash), \(sourceURI),
        \(event.collection), \(kind), \(event.eventTime),
        \(event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention))
      WHERE NOT EXISTS (
        SELECT 1 FROM wire_signal_events
        WHERE source_uri = \(sourceURI) AND occurred_at > \(event.eventTime)
      )
      ON CONFLICT DO NOTHING
      """,
      logger: logger
    )
  }

  private func replaceSignals(
    event: InboxEvent,
    canonicalKeys: [String],
    actorHash: String,
    sourceURI: String,
    kind: String,
    sourceCollection: String,
    sourceAction: String,
    asOf: Date
  ) async throws {
    let orderedKeys = Array(Set(canonicalKeys)).sorted()
    let eventKeyPrefix = "\(event.environment):\(event.sourceGeneration):\(event.sequence)"
    let transportKeyPrefix = Self.transportEventKey(
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
      for canonicalKey in orderedKeys {
        let eventKey = "\(eventKeyPrefix):\(canonicalKey)"
        let transportEventKey = "\(transportKeyPrefix):\(canonicalKey)"
        try await connection.query(
          """
          INSERT INTO wire_signal_events
            (event_key, transport_event_key, canonical_key, signal_kind, actor_key_hash, source_uri,
             source_collection, source_action, occurred_at, expires_at)
          SELECT
            \(eventKey), \(transportEventKey), \(canonicalKey), \(kind), \(actorHash), \(sourceURI),
            \(sourceCollection), \(sourceAction), \(event.eventTime),
            \(event.eventTime.addingTimeInterval(WireDataPolicy.signalRetention))
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
    try await PostgresWireSignalRollupStore(pool: pool, logger: logger).refresh(asOf: asOf)
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

  private func refreshCommunitiesIfNeeded(asOf: Date) async throws -> Date {
    let rows = try await pool.query(
      "SELECT MAX(assigned_at) FROM wire_actor_communities",
      logger: logger
    )
    var lastAssigned: Date?
    for try await row in rows { lastAssigned = try row.decode(Date?.self) }
    if let lastAssigned,
      asOf.timeIntervalSince(lastAssigned) < WireDataPolicy.clusteringCadence
    {
      return lastAssigned.addingTimeInterval(WireDataPolicy.clusteringCadence)
    }

    try await pruneActiveGraph(asOf: asOf)
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
            AND current.label > neighbor.minimum_label
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
          AND signal.community_key_hash IS DISTINCT FROM community.community_key_hash
        """,
        logger: logger
      )
      try await connection.query(
        """
        UPDATE wire_signal_events signal
        SET community_key_hash = NULL
        WHERE signal.community_key_hash IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM wire_actor_communities community
          WHERE community.actor_key_hash = signal.actor_key_hash)
        """,
        logger: logger
      )
    }
    return asOf.addingTimeInterval(WireDataPolicy.clusteringCadence)
  }

  private func finish(
    _ event: InboxEvent,
    status: String,
    retryAt: Date,
    reason: String?,
    asOf: Date,
    connection: PostgresConnection? = nil
  ) async throws -> Bool {
    try Task.checkCancellation()
    let appliedAt: Date? = status == "applied" ? asOf : nil
    let deadAt: Date? = status == "dead_letter" ? asOf : nil
    let expiresAt =
      status == "applied"
      ? asOf.addingTimeInterval(300)
      : status == "dead_letter" ? asOf.addingTimeInterval(7 * 24 * 3_600) : .distantFuture
    let rows = try await projectionQuery(
      """
      UPDATE wire_ingestion_inbox
      SET status = \(status), next_attempt_at = \(retryAt), failure_category = \(reason),
          failure_reason = \(reason), applied_at = \(appliedAt), dead_lettered_at = \(deadAt),
          lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
          expires_at = \(expiresAt), updated_at = \(asOf)
      WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
        AND seq = \(event.sequence) AND lease_token = \(event.leaseToken)
        AND status = 'leased'
      RETURNING seq
      """,
      on: connection
    )
    for try await _ in rows { return true }
    return false
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
