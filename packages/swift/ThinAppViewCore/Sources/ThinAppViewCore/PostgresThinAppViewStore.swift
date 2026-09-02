import Foundation
import Logging
import OperationsCore
import PostgresNIO

public actor PostgresThinAppViewStore: ThinAppViewStore {
  private let pool: PostgresClient
  private let logger: Logger

public init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  public func ping() async throws {
    let rows = try await pool.query("SELECT 1", logger: logger)
    for try await _ in rows { return }
  }

  public func claimIngestionInbox(
    environment: String,
    sourceGeneration: String,
    workerId: String,
    limit: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> [AppViewIngestionInboxItem] {
    let leaseToken = UUID().uuidString.lowercased()
    let authorCollections = AppViewIngestionScopePolicy.publicationAuthorCollections
    let viewerCollections = AppViewIngestionScopePolicy.viewerCollections
    let rows = try await pool.query(
      """
      WITH candidates AS (
        SELECT i.environment, i.source_generation, i.seq
        FROM appview_ingestion_inbox i
        WHERE i.environment = \(environment) AND i.source_generation = \(sourceGeneration)
          AND ((i.status IN ('pending', 'retry') AND i.next_attempt_at <= \(at))
            OR (i.status = 'leased' AND i.lease_expires_at <= \(at)))
          AND (
            (i.event_kind != 'commit' AND (
              EXISTS (
                SELECT 1 FROM appview_publication_scopes scope
                WHERE scope.author_did = i.repo_did OR scope.viewer_did = i.repo_did)
              OR EXISTS (
                SELECT 1 FROM appview_viewer_feeds feed
                WHERE feed.viewer_did = i.repo_did)))
            OR (i.collection = ANY(\(authorCollections)) AND EXISTS (
              SELECT 1 FROM appview_publication_scopes scope
              WHERE scope.author_did = i.repo_did))
            OR (i.collection = ANY(\(viewerCollections)) AND (
              EXISTS (
                SELECT 1 FROM appview_viewer_feeds feed
                WHERE feed.viewer_did = i.repo_did)
              OR EXISTS (
                SELECT 1 FROM appview_publication_scopes scope
                WHERE scope.viewer_did = i.repo_did)))
          )
          AND NOT EXISTS (
            SELECT 1
            FROM appview_ingestion_inbox earlier
            WHERE earlier.environment = i.environment
              AND earlier.source_generation = i.source_generation
              AND earlier.repo_did = i.repo_did
              AND earlier.seq < i.seq
              AND earlier.status IN ('pending', 'retry', 'leased')
          )
          AND NOT EXISTS (
            SELECT 1
            FROM appview_ingestion_reconciliation_requests request
            WHERE request.environment = i.environment
              AND request.source_generation = i.source_generation
              AND request.repo_did = i.repo_did
              AND request.status IN ('pending', 'leased')
          )
        ORDER BY i.seq ASC
        FOR UPDATE SKIP LOCKED
        LIMIT \(max(1, limit))
      )
      UPDATE appview_ingestion_inbox AS inbox
      SET status = 'leased', lease_owner = \(workerId), lease_token = \(leaseToken),
          lease_expires_at = \(leaseUntil), updated_at = \(at)
      FROM candidates
      WHERE inbox.environment = candidates.environment
        AND inbox.source_generation = candidates.source_generation
        AND inbox.seq = candidates.seq
      RETURNING inbox.seq, inbox.source_host, inbox.event_kind, inbox.repo_did,
                inbox.collection, inbox.operation, inbox.repo_rev, inbox.record_key,
                inbox.record_cid, inbox.payload::text, inbox.event_time, inbox.attempt_count
      """,
      logger: logger
    )
    var claimed: [AppViewIngestionInboxItem] = []
    for try await row in rows {
      let value = try row.decode(
        (Int64, String, String, String, String?, String?, String?, String?, String?, String, Date, Int).self
      )
      guard let eventKind = AppViewIngestionEventKind(rawValue: value.2),
        let payload = value.9.data(using: .utf8)
      else { throw AppViewIngestionInboxStoreError.invalidRow }
      claimed.append(
        AppViewIngestionInboxItem(
          environment: environment,
          sourceGeneration: sourceGeneration,
          sequence: value.0,
          sourceHost: value.1,
          eventKind: eventKind,
          repoDid: value.3,
          collection: value.4,
          operation: value.5,
          repoRev: value.6,
          recordKey: value.7,
          recordCID: value.8,
          payload: payload,
          eventTime: value.10,
          attemptCount: value.11,
          leaseToken: leaseToken,
          leaseExpiresAt: leaseUntil
        )
      )
    }
    return claimed.sorted { $0.sequence < $1.sequence }
  }

  public func filterIngestionInboxOutsideScope(
    environment: String,
    sourceGeneration: String,
    policy: String,
    limit: Int,
    expiresAt: Date,
    at: Date
  ) async throws -> Int {
    let authorCollections = AppViewIngestionScopePolicy.publicationAuthorCollections
    let viewerCollections = AppViewIngestionScopePolicy.viewerCollections
    let managedCollections = authorCollections + viewerCollections
    let rows = try await pool.query(
      """
      WITH candidates AS (
        SELECT inbox.environment, inbox.source_generation, inbox.seq
        FROM appview_ingestion_inbox inbox
        WHERE inbox.environment = \(environment)
          AND inbox.source_generation = \(sourceGeneration)
          AND ((inbox.status IN ('pending', 'retry') AND inbox.next_attempt_at <= \(at))
            OR (inbox.status = 'leased' AND inbox.lease_expires_at <= \(at)))
          AND (
            (inbox.event_kind = 'commit' AND (
              inbox.collection IS NULL OR inbox.collection != ALL(\(managedCollections))
              OR (inbox.collection = ANY(\(authorCollections)) AND NOT EXISTS (
                SELECT 1 FROM appview_publication_scopes scope
                WHERE scope.author_did = inbox.repo_did))
              OR (inbox.collection = ANY(\(viewerCollections))
                AND NOT EXISTS (
                  SELECT 1 FROM appview_viewer_feeds feed
                  WHERE feed.viewer_did = inbox.repo_did)
                AND NOT EXISTS (
                  SELECT 1 FROM appview_publication_scopes scope
                  WHERE scope.viewer_did = inbox.repo_did))))
            OR (inbox.event_kind != 'commit'
              AND NOT EXISTS (
                SELECT 1 FROM appview_publication_scopes scope
                WHERE scope.author_did = inbox.repo_did OR scope.viewer_did = inbox.repo_did)
              AND NOT EXISTS (
                SELECT 1 FROM appview_viewer_feeds feed
                WHERE feed.viewer_did = inbox.repo_did))
          )
        ORDER BY inbox.seq
        FOR UPDATE SKIP LOCKED
        LIMIT \(max(1, min(limit, 10_000)))
      )
      UPDATE appview_ingestion_inbox inbox
      SET status = 'filtered_scope', filtered_scope_policy = \(String(policy.prefix(128))),
          filtered_scope_at = \(at), applied_at = NULL, reconciled_at = NULL,
          lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
          failure_category = NULL, failure_reason = NULL,
          expires_at = \(expiresAt), updated_at = \(at)
      FROM candidates
      WHERE inbox.environment = candidates.environment
        AND inbox.source_generation = candidates.source_generation
        AND inbox.seq = candidates.seq
      RETURNING 1
      """,
      logger: logger
    )
    var filtered = 0
    for try await _ in rows { filtered += 1 }
    return filtered
  }

  public func markIngestionInboxApplied(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    expiresAt: Date,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_inbox
      SET status = 'applied', applied_at = \(at), lease_owner = NULL, lease_token = NULL,
          lease_expires_at = NULL, failure_category = NULL, failure_reason = NULL,
          expires_at = \(expiresAt), updated_at = \(at)
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        AND seq = \(sequence) AND status = 'leased'
        AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
      RETURNING 1
      """,
      logger: logger
    )
    var updated = false
    for try await _ in rows { updated = true }
    guard updated else { throw AppViewIngestionInboxStoreError.staleLease }
  }

  public func retryIngestionInbox(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    failureCategory: String,
    failureReason: String,
    nextAttemptAt: Date,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_inbox
      SET status = 'retry', attempt_count = attempt_count + 1,
          next_attempt_at = \(nextAttemptAt), lease_owner = NULL, lease_token = NULL,
          lease_expires_at = NULL, failure_category = \(failureCategory),
          failure_reason = \(String(failureReason.prefix(1_000))), updated_at = \(at)
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        AND seq = \(sequence) AND status = 'leased'
        AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
      RETURNING 1
      """,
      logger: logger
    )
    var updated = false
    for try await _ in rows { updated = true }
    guard updated else { throw AppViewIngestionInboxStoreError.staleLease }
  }

  public func advanceIngestionInboxAppliedWatermark(
    environment: String,
    sourceGeneration: String,
    at: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await Self.advanceAppliedInboxWatermark(
        connection: connection,
        environment: environment,
        sourceGeneration: sourceGeneration,
        at: at,
        logger: logger
      )
    }
  }

  public func renewIngestionInboxLease(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    leaseUntil: Date,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_inbox
      SET lease_expires_at = \(leaseUntil), updated_at = \(at)
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        AND seq = \(sequence) AND status = 'leased'
        AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
      RETURNING 1
      """,
      logger: logger
    )
    var updated = false
    for try await _ in rows { updated = true }
    guard updated else { throw AppViewIngestionInboxStoreError.staleLease }
  }

  public func deadLetterIngestionInbox(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    repoDid: String,
    workerId: String,
    leaseToken: String,
    failureCategory: String,
    failureReason: String,
    expiresAt: Date,
    at: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        UPDATE appview_ingestion_inbox
        SET status = 'dead_letter', attempt_count = attempt_count + 1,
            next_attempt_at = \(at), lease_owner = NULL, lease_token = NULL,
            lease_expires_at = NULL, failure_category = \(failureCategory),
            failure_reason = \(String(failureReason.prefix(1_000))), dead_lettered_at = \(at),
            expires_at = \(expiresAt), updated_at = \(at)
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND seq = \(sequence) AND status = 'leased'
          AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
        RETURNING 1
        """,
        logger: logger
      )
      var updated = false
      for try await _ in rows { updated = true }
      guard updated else { throw AppViewIngestionInboxStoreError.staleLease }
      let requestId = "\(sourceGeneration):\(sequence):\(repoDid)"
      try await connection.query(
        """
        INSERT INTO appview_ingestion_reconciliation_requests
          (environment, id, source_generation, repo_did, reason, trigger_seq, status,
           attempt_count, next_attempt_at, created_at, updated_at)
        VALUES
          (\(environment), \(requestId), \(sourceGeneration), \(repoDid), \(failureCategory),
           \(sequence), 'pending', 0, \(at), \(at), \(at))
        ON CONFLICT (environment, source_generation, repo_did, trigger_seq, reason) DO NOTHING
        """,
        logger: logger
      )
    }
  }

  public func markIngestionInboxReconciled(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    repoDid: String,
    repoRev: String,
    workerId: String,
    leaseToken: String,
    expiresAt: Date,
    at: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        UPDATE appview_ingestion_inbox
        SET reconciled_at = \(at), expires_at = \(expiresAt),
            updated_at = \(at)
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND seq = \(sequence) AND repo_did = \(repoDid)
          AND status = 'leased' AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
        RETURNING 1
        """,
        logger: logger
      )
      var updated = false
      for try await _ in rows { updated = true }
      guard updated else { throw AppViewIngestionInboxStoreError.staleLease }
      try await connection.query(
        """
        UPDATE appview_jetstream_checkpoints
        SET last_reconciled_repo_rev = \(repoRev), last_reconciled_at = \(at), updated_at = \(at)
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        """,
        logger: logger
      )
      try await connection.query(
        """
        UPDATE appview_ingestion_reconciliation_requests
        SET status = 'completed', completed_at = \(at), updated_at = \(at),
            lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND repo_did = \(repoDid) AND trigger_seq = \(sequence) AND status != 'completed'
        """,
        logger: logger
      )
      try await Self.advanceAppliedInboxWatermark(
        connection: connection,
        environment: environment,
        sourceGeneration: sourceGeneration,
        at: at,
        logger: logger
      )
    }
  }

  public func deleteExpiredIngestionInbox(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let rows = try await pool.query(
      """
      WITH expired AS (
        SELECT environment, source_generation, seq
        FROM appview_ingestion_inbox
        WHERE environment = \(environment) AND expires_at <= \(before)
          AND (status IN ('applied', 'filtered_scope')
            OR (status = 'dead_letter' AND reconciled_at IS NOT NULL))
        ORDER BY expires_at ASC, seq ASC
        LIMIT \(max(1, batchSize))
        FOR UPDATE SKIP LOCKED
      )
      DELETE FROM appview_ingestion_inbox inbox
      USING expired
      WHERE inbox.environment = expired.environment
        AND inbox.source_generation = expired.source_generation
        AND inbox.seq = expired.seq
      RETURNING 1
      """,
      logger: logger
    )
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func resolveRecoveredIngestionIncidents(
    environment: String,
    sourceGeneration: String,
    at: Date
  ) async throws -> Int {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_incidents incident
      SET status = 'resolved', replay_state = 'live',
          replay_sealed_seq = checkpoint.replay_sealed_seq,
          recovered_through_cursor = checkpoint.last_applied_seq,
          verification_evidence = incident.verification_evidence || jsonb_build_object(
            'recovery', 'terminal_prefix_reached',
            'sealedSequence', checkpoint.replay_sealed_seq::text,
            'terminalPrefixSequence', checkpoint.last_applied_seq::text,
            'allStagedRowsThroughSealedTerminal', true),
          resolved_at = \(at), updated_at = \(at), version = incident.version + 1
      FROM appview_jetstream_checkpoints checkpoint
      WHERE checkpoint.environment = \(environment)
        AND checkpoint.source_generation = \(sourceGeneration)
        AND checkpoint.replay_state = 'live'
        AND checkpoint.replay_sealed_seq IS NOT NULL
        AND checkpoint.last_applied_seq >= checkpoint.replay_sealed_seq
        AND incident.environment = checkpoint.environment
        AND incident.source_generation = checkpoint.source_generation
        AND incident.source = 'jetstream-v2'
        AND incident.cursor_kind = 'jetstream_v2_seq'
        AND incident.category IN (
          'transport_error', 'consumer_too_slow', 'cursor_too_old', 'replay_budget',
          'no_progress_24h')
        AND incident.status IN ('open', 'recovering')
        AND NOT EXISTS (
          SELECT 1 FROM appview_ingestion_inbox inbox
          WHERE inbox.environment = checkpoint.environment
            AND inbox.source_generation = checkpoint.source_generation
            AND inbox.seq <= checkpoint.replay_sealed_seq
            AND inbox.status NOT IN ('applied', 'filtered_scope')
            AND inbox.reconciled_at IS NULL)
      RETURNING 1
      """,
      logger: logger
    )
    var resolved = 0
    for try await _ in rows { resolved += 1 }
    return resolved
  }

  public func resolveTerminalRetiredGenerationIncidents(
    environment: String,
    activeSourceGeneration: String,
    activeLeaseName: String,
    at: Date
  ) async throws -> Int {
    let rows = try await pool.query(
      """
      WITH successor AS (
        SELECT checkpoint.source_generation, checkpoint.source_host,
               checkpoint.stream_nsid, checkpoint.cursor_kind,
               checkpoint.replay_after_seq, checkpoint.last_staged_seq,
               checkpoint.updated_at AS checkpoint_observed_at,
               lease.updated_at AS lease_observed_at
        FROM appview_jetstream_checkpoints checkpoint
        JOIN LATERAL (
          SELECT candidate.updated_at
          FROM appview_ingestion_leases candidate
          WHERE candidate.environment = checkpoint.environment
            AND candidate.source_generation = checkpoint.source_generation
            AND candidate.lease_name = \(activeLeaseName)
            AND candidate.released_at IS NULL
            AND candidate.lease_expires_at >= \(at)
          ORDER BY candidate.updated_at DESC
          LIMIT 1
        ) lease ON TRUE
        WHERE checkpoint.environment = \(environment)
          AND checkpoint.source_generation = \(activeSourceGeneration)
          AND checkpoint.replay_state = 'live'
      ), retired AS (
        SELECT checkpoint.source_generation, checkpoint.last_staged_seq,
               checkpoint.last_applied_seq
        FROM appview_jetstream_checkpoints checkpoint
        CROSS JOIN successor
        WHERE checkpoint.environment = \(environment)
          AND checkpoint.source_generation != successor.source_generation
          AND checkpoint.source_host = successor.source_host
          AND checkpoint.stream_nsid = successor.stream_nsid
          AND checkpoint.cursor_kind = successor.cursor_kind
          AND successor.replay_after_seq < checkpoint.last_staged_seq
          AND successor.last_staged_seq >= checkpoint.last_staged_seq
          AND checkpoint.replay_state = 'live'
          AND checkpoint.last_staged_seq IS NOT NULL
          AND checkpoint.last_applied_seq IS NOT NULL
          AND checkpoint.last_applied_seq >= checkpoint.last_staged_seq
          AND NOT EXISTS (
            SELECT 1 FROM appview_ingestion_leases retired_lease
            WHERE retired_lease.environment = checkpoint.environment
              AND retired_lease.source_generation = checkpoint.source_generation
              AND retired_lease.released_at IS NULL
              AND retired_lease.lease_expires_at >= \(at))
          AND NOT EXISTS (
            SELECT 1 FROM appview_ingestion_inbox inbox
            WHERE inbox.environment = checkpoint.environment
              AND inbox.source_generation = checkpoint.source_generation
              AND (inbox.seq > checkpoint.last_staged_seq
                OR NOT (
                  inbox.status IN ('applied', 'filtered_scope')
                  OR (inbox.status = 'dead_letter' AND inbox.reconciled_at IS NOT NULL))))
          AND NOT EXISTS (
            SELECT 1 FROM appview_ingestion_reconciliation_requests request
            WHERE request.environment = checkpoint.environment
              AND request.source_generation = checkpoint.source_generation
              AND request.status IN ('pending', 'leased', 'failed'))
      )
      UPDATE appview_ingestion_incidents incident
      SET status = 'resolved', replay_state = 'live',
          recovered_through_cursor = retired.last_applied_seq,
          verification_evidence = incident.verification_evidence || jsonb_build_object(
            'recovery', 'retired_generation_terminal',
            'resolutionPolicy', 'retired-generation-terminal-v1',
            'retiredSourceGeneration', retired.source_generation,
            'successorSourceGeneration', successor.source_generation,
            'successorLeaseName', \(activeLeaseName),
            'successorReplayAfterSequence', successor.replay_after_seq::text,
            'successorLastStagedSequence', successor.last_staged_seq::text,
            'identityAndInclusiveOverlapVerified', true,
            'retiredLastStagedSequence', retired.last_staged_seq::text,
            'retiredTerminalPrefixSequence', retired.last_applied_seq::text,
            'allRetiredRowsTerminal', true,
            'successorCheckpointObservedAt', successor.checkpoint_observed_at,
            'successorLeaseObservedAt', successor.lease_observed_at),
          resolved_at = \(at), updated_at = \(at), version = incident.version + 1
      FROM retired CROSS JOIN successor
      WHERE incident.environment = \(environment)
        AND incident.source_generation = retired.source_generation
        AND incident.source = 'jetstream-v2'
        AND incident.cursor_kind = 'jetstream_v2_seq'
        AND incident.category = 'fatal_stream'
        AND incident.status IN ('open', 'recovering')
        AND (incident.start_cursor IS NULL
          OR incident.start_cursor <= retired.last_applied_seq)
        AND (incident.end_cursor IS NULL
          OR incident.end_cursor <= retired.last_applied_seq)
      RETURNING 1
      """,
      logger: logger
    )
    var resolved = 0
    for try await _ in rows { resolved += 1 }
    return resolved
  }

  public func claimIngestionReconciliationRequests(
    environment: String,
    sourceGeneration: String,
    workerId: String,
    limit: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> [AppViewIngestionReconciliationRequest] {
    let leaseToken = UUID().uuidString.lowercased()
    let rows = try await pool.query(
      """
      WITH candidates AS (
        SELECT request.environment, request.id
        FROM appview_ingestion_reconciliation_requests request
        WHERE request.environment = \(environment)
          AND request.source_generation = \(sourceGeneration)
          AND ((request.status = 'pending' AND request.next_attempt_at <= \(at))
            OR (request.status = 'leased' AND request.lease_expires_at <= \(at)))
          AND NOT EXISTS (
            SELECT 1 FROM appview_ingestion_reconciliation_requests earlier
            WHERE earlier.environment = request.environment
              AND earlier.source_generation = request.source_generation
              AND earlier.repo_did = request.repo_did
              AND earlier.trigger_seq < request.trigger_seq
              AND earlier.status IN ('pending', 'leased'))
          AND NOT EXISTS (
            SELECT 1 FROM appview_ingestion_inbox inbox
            WHERE inbox.environment = request.environment
              AND inbox.source_generation = request.source_generation
              AND inbox.repo_did = request.repo_did
              AND inbox.status = 'leased'
              AND inbox.lease_expires_at > \(at))
        ORDER BY request.trigger_seq, request.id
        FOR UPDATE SKIP LOCKED
        LIMIT \(max(1, limit))
      )
      UPDATE appview_ingestion_reconciliation_requests request
      SET status = 'leased', lease_owner = \(workerId), lease_token = \(leaseToken),
          lease_expires_at = \(leaseUntil), updated_at = \(at)
      FROM candidates
      WHERE request.environment = candidates.environment AND request.id = candidates.id
      RETURNING request.id, request.repo_did, request.reason, request.trigger_seq,
                request.attempt_count
      """,
      logger: logger
    )
    var requests: [AppViewIngestionReconciliationRequest] = []
    for try await row in rows {
      let value = try row.decode((String, String, String, Int64, Int).self)
      requests.append(AppViewIngestionReconciliationRequest(
        environment: environment, id: value.0, sourceGeneration: sourceGeneration,
        repoDid: value.1, reason: value.2, triggerSequence: value.3,
        attemptCount: value.4, leaseToken: leaseToken, leaseExpiresAt: leaseUntil))
    }
    return requests
  }

  public func renewIngestionReconciliationLease(
    environment: String,
    requestId: String,
    workerId: String,
    leaseToken: String,
    leaseUntil: Date,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_reconciliation_requests
      SET lease_expires_at = \(leaseUntil), updated_at = \(at)
      WHERE environment = \(environment) AND id = \(requestId) AND status = 'leased'
        AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
      RETURNING 1
      """, logger: logger)
    for try await _ in rows { return }
    throw AppViewIngestionInboxStoreError.staleLease
  }

  public func retryIngestionReconciliation(
    environment: String,
    requestId: String,
    workerId: String,
    leaseToken: String,
    failureReason: String,
    nextAttemptAt: Date,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_reconciliation_requests
      SET status = CASE WHEN attempt_count + 1 >= 10 THEN 'failed' ELSE 'pending' END,
          attempt_count = attempt_count + 1, next_attempt_at = \(nextAttemptAt),
          lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
          reason = CASE WHEN attempt_count + 1 >= 10
            THEN reason || ':reconciliation_failed:' || \(String(failureReason.prefix(512)))
            ELSE reason END,
          updated_at = \(at)
      WHERE environment = \(environment) AND id = \(requestId) AND status = 'leased'
        AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
      RETURNING 1
      """, logger: logger)
    for try await _ in rows { return }
    throw AppViewIngestionInboxStoreError.staleLease
  }

  public func completeIngestionReconciliation(
    environment: String,
    requestId: String,
    sourceGeneration: String,
    repoDid: String,
    triggerSequence: Int64,
    workerId: String,
    leaseToken: String,
    expiresAt: Date,
    at: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let fenced = try await connection.query(
        """
        UPDATE appview_ingestion_reconciliation_requests
        SET status = 'completed', completed_at = \(at), updated_at = \(at),
            lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL
        WHERE environment = \(environment) AND id = \(requestId) AND status = 'leased'
          AND lease_owner = \(workerId) AND lease_token = \(leaseToken)
        RETURNING 1
        """, logger: logger)
      var updated = false
      for try await _ in fenced { updated = true }
      guard updated else { throw AppViewIngestionInboxStoreError.staleLease }
      let inboxRows = try await connection.query(
        """
        UPDATE appview_ingestion_inbox
        SET reconciled_at = \(at), expires_at = \(expiresAt), updated_at = \(at)
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND seq = \(triggerSequence) AND repo_did = \(repoDid) AND status = 'dead_letter'
        RETURNING 1
        """, logger: logger)
      var inboxUpdated = false
      for try await _ in inboxRows { inboxUpdated = true }
      guard inboxUpdated else { throw AppViewIngestionInboxStoreError.invalidRow }
      try await connection.query(
        """
        UPDATE appview_jetstream_checkpoints checkpoint
        SET last_reconciled_repo_rev = COALESCE(inbox.repo_rev, checkpoint.last_reconciled_repo_rev),
            last_reconciled_at = \(at), updated_at = \(at)
        FROM appview_ingestion_inbox inbox
        WHERE checkpoint.environment = \(environment)
          AND checkpoint.source_generation = \(sourceGeneration)
          AND inbox.environment = checkpoint.environment
          AND inbox.source_generation = checkpoint.source_generation
          AND inbox.seq = \(triggerSequence)
        """, logger: logger)
      try await Self.advanceAppliedInboxWatermark(
        connection: connection, environment: environment,
        sourceGeneration: sourceGeneration, at: at, logger: logger)
    }
  }

  public func upsertContentItem(_ item: IndexedContentItem) async throws {
    let renderJSON = try item.render.encodedJSON()
    try await pool.query(
      """
      INSERT INTO content_items
        (uri, cid, author_did, collection, created_at, indexed_at, publication_site, render_json, expires_at)
      VALUES
        (\(item.uri), \(item.cid), \(item.authorDid), \(item.collection), \(item.createdAt), \(item.indexedAt), \(item.publicationSite), \(renderJSON)::jsonb, \(item.expiresAt))
      ON CONFLICT (uri) DO UPDATE SET
        cid = EXCLUDED.cid,
        author_did = EXCLUDED.author_did,
        collection = EXCLUDED.collection,
        created_at = EXCLUDED.created_at,
        indexed_at = EXCLUDED.indexed_at,
        publication_site = EXCLUDED.publication_site,
        render_json = EXCLUDED.render_json,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  public func deleteContentItem(uri: String) async throws {
    try await pool.query(
      "DELETE FROM content_items WHERE uri = \(uri)",
      logger: logger
    )
  }

  public func deleteContentItems(authorDid: String) async throws -> Int {
    let rows = try await pool.query(
      "DELETE FROM content_items WHERE author_did = \(authorDid) RETURNING 1",
      logger: logger
    )
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func deleteContentItems(
    authorDid: String,
    excludingURIs: [String],
    indexedAtOrBefore: Date
  ) async throws -> Int {
    let rows = if excludingURIs.isEmpty {
      try await pool.query(
        """
        DELETE FROM content_items
        WHERE author_did = \(authorDid)
          AND indexed_at <= \(indexedAtOrBefore)
        RETURNING 1
        """,
        logger: logger
      )
    } else {
      try await pool.query(
        """
        DELETE FROM content_items
        WHERE author_did = \(authorDid)
          AND indexed_at <= \(indexedAtOrBefore)
          AND NOT (uri = ANY(\(excludingURIs)))
        RETURNING 1
        """,
        logger: logger
      )
    }
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func fetchContentIdentity(uri: String) async throws -> IndexedContentIdentity? {
    let rows = try await pool.query(
      """
      SELECT uri, cid, author_did, collection
      FROM content_items
      WHERE uri = \(uri)
        AND expires_at > NOW()
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (storedUri, cid, authorDid, collection) = try row.decode(
        (String, String, String, String).self
      )
      return IndexedContentIdentity(
        uri: storedUri,
        cid: cid,
        authorDid: authorDid,
        collection: collection
      )
    }
    return nil
  }

  public func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO read_marks (viewer_did, subject_uri, created_at)
        VALUES (\(viewerDid), \(subjectUri), \(createdAt))
        ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = EXCLUDED.created_at
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM appview_unread_overrides
        WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
        """,
        logger: logger
      )
    }
  }

  public func deleteReadMark(viewerDid: String, subjectUri: String) async throws {
    try await pool.query(
      """
      DELETE FROM read_marks
      WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
      """,
      logger: logger
    )
  }

  public func upsertReadMarks(
    viewerDid: String,
    subjectUris: [String],
    createdAt: Date
  ) async throws {
    let subjects = Array(Set(subjectUris)).sorted()
    guard !subjects.isEmpty else { return }
    let countedAt = Date()
    let generation = AppViewUnreadCounterSupport.generation(for: countedAt)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO read_marks (viewer_did, subject_uri, created_at)
        SELECT \(viewerDid), subject_uri, \(createdAt)
        FROM unnest(\(subjects)::text[]) AS subjects(subject_uri)
        ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = EXCLUDED.created_at
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM appview_unread_overrides
        WHERE viewer_did = \(viewerDid) AND subject_uri = ANY(\(subjects))
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO appview_unread_counters
          (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
        SELECT DISTINCT scope.viewer_did, scope.publication_id, 0,
          \(generation), \(AppViewUnreadCounterAccuracy.estimated.rawValue), TRUE, \(countedAt)
        FROM appview_publication_scopes scope
        JOIN content_items ci ON ci.author_did = scope.author_did
          AND (
            jsonb_array_length(scope.scope_keys) = 0
            OR (ci.publication_site IS NOT NULL AND scope.scope_keys ? ci.publication_site)
          )
        WHERE scope.viewer_did = \(viewerDid) AND ci.uri = ANY(\(subjects))
        ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
          generation = EXCLUDED.generation,
          accuracy = EXCLUDED.accuracy,
          dirty = TRUE,
          counted_at = EXCLUDED.counted_at
        """,
        logger: logger
      )
    }
  }

  public func markEntryUnread(
    viewerDid: String,
    subjectUri: String,
    createdAt: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        DELETE FROM read_marks
        WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO appview_unread_overrides (viewer_did, subject_uri, created_at)
        VALUES (\(viewerDid), \(subjectUri), \(createdAt))
        ON CONFLICT (viewer_did, subject_uri)
        DO UPDATE SET created_at = EXCLUDED.created_at
        """,
        logger: logger
      )
    }
  }

  public func purgeReadMarks(viewerDid: String) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM read_marks WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM appview_unread_overrides WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
    }
  }

  public func fetchContentItem(uri: String) async throws -> AppViewEntryListItem? {
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
      FROM content_items ci
      WHERE ci.uri = \(uri) AND ci.expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (uri, renderJSON, createdAt, publicationSite) = try row.decode(
        (String, String, Date, String?).self
      )
      let item = ThinAppViewQuerySupport.entryListItems(
        from: [(uri, renderJSON, createdAt)]
      ).first
      if let publicationSite {
        return item?.withPublicationId(publicationSite)
      }
      return item
    }
    return nil
  }

  public func fetchContentRender(uri: String) async throws -> ContentRenderFields? {
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.render_json::text
      FROM content_items ci
      WHERE ci.uri = \(uri) AND ci.expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    let decoder = JSONDecoder()
    for try await row in rows {
      let renderJSON: String = try row.decode(String.self)
      guard let data = renderJSON.data(using: .utf8) else { return nil }
      return try? decoder.decode(ContentRenderFields.self, from: data)
    }
    return nil
  }

  public func listContentItemsForPublicationSite(
    authorDid: String,
    publicationSite: String,
    limit: Int
  ) async throws -> [(uri: String, renderJSON: String)] {
    let capped = max(1, min(limit, 2_000))
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.uri, ci.render_json::text
      FROM content_items ci
      WHERE ci.author_did = \(authorDid)
        AND ci.publication_site = \(publicationSite)
        AND ci.expires_at > \(now)
      ORDER BY ci.created_at DESC, ci.uri DESC
      LIMIT \(capped)
      """,
      logger: logger
    )
    var items: [(uri: String, renderJSON: String)] = []
    for try await row in rows {
      let (uri, renderJSON): (String, String) = try row.decode((String, String).self)
      items.append((uri, renderJSON))
    }
    return items
  }

  public func hasReadMark(viewerDid: String, subjectUri: String) async throws -> Bool {
    let rows = try await pool.query(
      """
      SELECT 1 AS present
      FROM read_marks
      WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
      LIMIT 1
      """,
      logger: logger
    )
    for try await _ in rows { return true }
    return false
  }

  public func readStates(
    viewerDid: String,
    entries: [AppViewEntryListItem]
  ) async throws -> [String: Bool] {
    guard !entries.isEmpty else { return [:] }
    let entryIds = Array(Set(entries.map(\.entryId))).sorted()
    let publicationIds = Array(Set(entries.compactMap(\.publicationId))).sorted()
    let readRows = try await pool.query(
      """
      SELECT subject_uri FROM read_marks
      WHERE viewer_did = \(viewerDid) AND subject_uri = ANY(\(entryIds))
      """,
      logger: logger
    )
    var explicitReads = Set<String>()
    for try await row in readRows {
      explicitReads.insert(try row.decode(String.self))
    }
    let overrideRows = try await pool.query(
      """
      SELECT subject_uri FROM appview_unread_overrides
      WHERE viewer_did = \(viewerDid) AND subject_uri = ANY(\(entryIds))
      """,
      logger: logger
    )
    var unreadOverrides = Set<String>()
    for try await row in overrideRows {
      unreadOverrides.insert(try row.decode(String.self))
    }
    let boundaries = try await readBoundaries(
      viewerDid: viewerDid,
      publicationIds: publicationIds
    )
    return Dictionary(uniqueKeysWithValues: entries.map { entry in
      let covered = entry.publicationId
        .flatMap { boundaries[$0] }?
        .contains(createdAt: entry.feedPositionAt, entryId: entry.entryId) ?? false
      return (
        entry.entryId,
        explicitReads.contains(entry.entryId)
          || (covered && !unreadOverrides.contains(entry.entryId))
      )
    })
  }

  public func listEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int,
    readBoundary: ReadWatermarkBoundary?
  ) async throws -> AppViewEntryListResponse {
    let pageLimit = max(1, min(limit, 100))
    let now = Date()
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    let batchSize = ThinAppViewQuerySupport.scanBatchSize(
      pageLimit: pageLimit,
      scoped: scoped
    )
    var dbCursor = cursor.flatMap { ThinAppViewCursor.decode($0) }

    let siteKeys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    if scoped, !siteKeys.isEmpty {
      let fetched = try await fetchSiteScopedContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        siteKeys: siteKeys,
        filter: filter,
        cursor: dbCursor,
        limit: pageLimit + 1,
        now: now,
        readBoundary: readBoundary
      )
      return ThinAppViewQuerySupport.buildFilteredEntryListPage(
        pageLimit: pageLimit,
        matches: fetched.map {
          EntryListScanRow(
            uri: $0.uri,
            renderJSON: $0.renderJSON,
            createdAt: $0.createdAt,
            publicationSite: $0.publicationSite
          )
        },
        lastScannedCreatedAt: fetched.last?.createdAt,
        lastScannedUri: fetched.last?.uri,
        dbHasMore: fetched.count > pageLimit
      )
    }

    if !scoped {
      let fetched = try await fetchContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        filter: filter,
        cursor: dbCursor,
        limit: batchSize,
        now: now,
        readBoundary: readBoundary
      )
      return ThinAppViewQuerySupport.buildFilteredEntryListPage(
        pageLimit: pageLimit,
        matches: fetched.map {
          EntryListScanRow(
            uri: $0.uri,
            renderJSON: $0.renderJSON,
            createdAt: $0.createdAt,
            publicationSite: $0.publicationSite
          )
        },
        lastScannedCreatedAt: fetched.last?.createdAt,
        lastScannedUri: fetched.last?.uri,
        dbHasMore: fetched.count == batchSize
      )
    }

    var matches: [EntryListScanRow] = []
    var lastScannedCreatedAt: Date?
    var lastScannedUri: String?
    var dbHasMore = false

    scanLoop: while matches.count < pageLimit + 1 {
      let fetched = try await fetchContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        filter: filter,
        cursor: dbCursor,
        limit: batchSize,
        now: now,
        readBoundary: readBoundary
      )
      if fetched.isEmpty {
        dbHasMore = false
        break
      }

      dbHasMore = fetched.count == batchSize
      for row in fetched {
        lastScannedCreatedAt = row.createdAt
        lastScannedUri = row.uri
        guard
          ThinAppViewQuerySupport.publicationSiteMatches(
            siteField: row.publicationSite,
            publicationAtUri: publicationAtUri,
            publicationScopeAtUris: publicationScopeAtUris,
            publicationSiteUrls: publicationSiteUrls
          )
        else { continue }

        matches.append(
          EntryListScanRow(
            uri: row.uri,
            renderJSON: row.renderJSON,
            createdAt: row.createdAt,
            publicationSite: row.publicationSite
          )
        )
        if matches.count >= pageLimit + 1 {
          break scanLoop
        }
      }

      if !dbHasMore { break }
      guard let last = fetched.last else { break }
      dbCursor = (last.createdAt, last.uri)
    }

    return ThinAppViewQuerySupport.buildFilteredEntryListPage(
      pageLimit: pageLimit,
      matches: matches,
      lastScannedCreatedAt: lastScannedCreatedAt,
      lastScannedUri: lastScannedUri,
      dbHasMore: dbHasMore
    )
  }

  public func listFeedEntries(
    viewerDid: String,
    scopes: [PublicationUnreadScope],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    let pageLimit = max(1, min(limit, 100))
    let publicationIds = Array(Set(scopes.map(\.publicationId))).sorted()
    guard !publicationIds.isEmpty else {
      return AppViewEntryListResponse(entries: [], cursor: nil)
    }

    let now = Date()
    let decodedCursor = cursor.flatMap(ThinAppViewCursor.decode)
    let hasCursor = decodedCursor != nil
    let cursorAt = decodedCursor?.createdAt ?? now
    let cursorUri = decodedCursor?.uri ?? ""
    let includeAll = filter == .all
    let includeUnread = filter == .unread
    let includeRead = filter == .read
    let rows = try await pool.query(
      """
      SELECT ci.uri, ci.render_json::text, ci.created_at, scope.publication_id
      FROM appview_publication_scopes scope
      JOIN content_items ci
        ON ci.author_did = scope.author_did
       AND (
         jsonb_array_length(scope.scope_keys) = 0
         OR (ci.publication_site IS NOT NULL AND scope.scope_keys ? ci.publication_site)
       )
      LEFT JOIN appview_publication_read_floors floor
        ON floor.viewer_did = scope.viewer_did
       AND floor.publication_id = scope.publication_id
      LEFT JOIN read_marks rm
        ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
      LEFT JOIN appview_unread_overrides uo
        ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
      WHERE scope.viewer_did = \(viewerDid)
        AND scope.publication_id = ANY(\(publicationIds))
        AND ci.expires_at > \(now)
        AND (
        \(includeAll)
        OR (
          \(includeUnread)
          AND rm.subject_uri IS NULL
          AND (
            floor.read_floor_at IS NULL
            OR ci.created_at > floor.read_floor_at
            OR (
              floor.read_floor_uri IS NOT NULL
              AND ci.created_at = floor.read_floor_at
              AND ci.uri > floor.read_floor_uri
            )
            OR uo.subject_uri IS NOT NULL
          )
        )
        OR (
          \(includeRead)
          AND (
            rm.subject_uri IS NOT NULL
            OR (
              floor.read_floor_at IS NOT NULL
              AND uo.subject_uri IS NULL
              AND (
                ci.created_at < floor.read_floor_at
                OR (
                  ci.created_at = floor.read_floor_at
                  AND (floor.read_floor_uri IS NULL OR ci.uri <= floor.read_floor_uri)
                )
              )
            )
          )
        )
      )
        AND (
          \(hasCursor) = FALSE
          OR ci.created_at < \(cursorAt)
          OR (ci.created_at = \(cursorAt) AND ci.uri < \(cursorUri))
        )
      ORDER BY ci.created_at DESC, ci.uri DESC
      LIMIT \(pageLimit + 1)
      """,
      logger: logger
    )

    var entries: [AppViewEntryListItem] = []
    for try await row in rows {
      let (uri, renderJSON, createdAt, publicationId) = try row.decode(
        (String, String, Date, String).self
      )
      guard let entry = ThinAppViewQuerySupport.entryListItems(
        from: [(uri, renderJSON, createdAt)]
      ).first else { continue }
      entries.append(entry.withPublicationId(publicationId))
    }
    let hasMore = entries.count > pageLimit
    let pageEntries = Array(entries.prefix(pageLimit))
    return AppViewEntryListResponse(
      entries: pageEntries,
      cursor: hasMore ? pageEntries.last.map {
        ThinAppViewCursor.encode(createdAt: $0.feedPositionAt, uri: $0.entryId)
      } : nil
    )
  }

  public func listFeedEntries(
    viewerDid: String,
    selector: AppViewFeedSelector,
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewFeedPage? {
    let pageLimit = max(1, min(limit, 100))
    let now = Date()
    let decodedCursor = cursor.flatMap(ThinAppViewCursor.decode)
    let hasCursor = decodedCursor != nil
    let cursorAt = decodedCursor?.createdAt ?? now
    let cursorUri = decodedCursor?.uri ?? ""
    let includeAll = filter == .all
    let includeUnread = filter == .unread
    let includeRead = filter == .read
    let kind = selector.kind.rawValue
    let feedId = selector.id
    let isPublication = selector.kind == .publication
    let databaseStartedAt = Date()

    let rows = try await pool.query(
      """
      WITH feed_definition AS (
        SELECT MAX(updated_at) AS updated_at
        FROM (
          SELECT vf.updated_at
          FROM appview_viewer_feeds vf
          WHERE \(isPublication) = FALSE
            AND vf.viewer_did = \(viewerDid)
            AND vf.feed_kind = \(kind)
            AND vf.feed_id = \(feedId)
          UNION ALL
          SELECT scope.updated_at
          FROM appview_publication_scopes scope
          WHERE \(isPublication) = TRUE
            AND scope.viewer_did = \(viewerDid)
            AND (
              scope.publication_id = \(feedId)
              OR scope.publication_at_uri = \(feedId)
              OR scope.scope_keys ? \(feedId)
            )
        ) definitions
      ), matching_scope_keys AS (
        SELECT DISTINCT
          keys.viewer_did,
          keys.publication_id,
          keys.author_did,
          keys.scope_key
        FROM appview_publication_scopes scope
        JOIN appview_publication_scope_keys keys
          ON keys.viewer_did = scope.viewer_did
         AND keys.publication_id = scope.publication_id
        LEFT JOIN appview_feed_publications membership
          ON membership.viewer_did = scope.viewer_did
         AND membership.publication_id = scope.publication_id
         AND membership.feed_kind = \(kind)
         AND membership.feed_id = \(feedId)
        WHERE scope.viewer_did = \(viewerDid)
          AND (
            (\(isPublication) = FALSE AND membership.publication_id IS NOT NULL)
            OR (
              \(isPublication) = TRUE
              AND (
                scope.publication_id = \(feedId)
                OR scope.publication_at_uri = \(feedId)
                OR scope.scope_keys ? \(feedId)
              )
            )
          )
      ), matched_content AS (
        SELECT
          scope.viewer_did,
          scope.publication_id,
          ci.uri,
          ci.render_json,
          ci.created_at
        FROM matching_scope_keys scope
        JOIN content_items ci
          ON ci.author_did = scope.author_did
         AND ci.publication_site = scope.scope_key
        WHERE scope.scope_key <> ''
          AND ci.expires_at > \(now)
          AND (
            \(hasCursor) = FALSE
            OR ci.created_at < \(cursorAt)
            OR (ci.created_at = \(cursorAt) AND ci.uri < \(cursorUri))
          )
        UNION ALL
        SELECT
          scope.viewer_did,
          scope.publication_id,
          ci.uri,
          ci.render_json,
          ci.created_at
        FROM matching_scope_keys scope
        JOIN content_items ci ON ci.author_did = scope.author_did
        WHERE scope.scope_key = ''
          AND ci.expires_at > \(now)
          AND (
            \(hasCursor) = FALSE
            OR ci.created_at < \(cursorAt)
            OR (ci.created_at = \(cursorAt) AND ci.uri < \(cursorUri))
          )
      ), candidates AS (
        SELECT
          content.uri,
          content.render_json::text AS render_json,
          content.created_at,
          content.publication_id,
          CASE
            WHEN uo.subject_uri IS NOT NULL THEN FALSE
            WHEN rm.subject_uri IS NOT NULL THEN TRUE
            WHEN floor.read_floor_at IS NULL THEN FALSE
            WHEN content.created_at < floor.read_floor_at THEN TRUE
            WHEN content.created_at = floor.read_floor_at
              AND (floor.read_floor_uri IS NULL OR content.uri <= floor.read_floor_uri) THEN TRUE
            ELSE FALSE
          END AS is_read,
          ROW_NUMBER() OVER (
            PARTITION BY COALESCE(NULLIF(content.render_json->>'articleUrl', ''), content.uri)
            ORDER BY content.created_at DESC, content.uri DESC
          ) AS duplicate_rank
        FROM matched_content content
        LEFT JOIN appview_publication_read_floors floor
          ON floor.viewer_did = content.viewer_did
         AND floor.publication_id = content.publication_id
        LEFT JOIN read_marks rm
          ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = content.uri
        LEFT JOIN appview_unread_overrides uo
          ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = content.uri
      ), page AS (
        SELECT uri, render_json, created_at, publication_id, is_read
        FROM candidates
        WHERE duplicate_rank = 1
          AND (
            \(includeAll)
            OR (\(includeUnread) AND is_read = FALSE)
            OR (\(includeRead) AND is_read = TRUE)
          )
        ORDER BY created_at DESC, uri DESC
        LIMIT \(pageLimit + 1)
      )
      SELECT
        definition.updated_at,
        page.uri,
        page.render_json,
        page.created_at,
        page.publication_id,
        page.is_read
      FROM feed_definition definition
      LEFT JOIN LATERAL (
        SELECT * FROM page ORDER BY created_at DESC, uri DESC
      ) page ON TRUE
      WHERE definition.updated_at IS NOT NULL
      ORDER BY page.created_at DESC NULLS LAST, page.uri DESC NULLS LAST
      """,
      logger: logger
    )

    var membershipUpdatedAt: Date?
    var entries: [AppViewEntryListItem] = []
    for try await row in rows {
      let (updatedAt, uri, renderJSON, createdAt, publicationId, isRead) = try row.decode(
        (Date, String?, String?, Date?, String?, Bool?).self
      )
      membershipUpdatedAt = updatedAt
      guard let uri, let renderJSON, let createdAt, let publicationId,
            let entry = ThinAppViewQuerySupport.entryListItems(
              from: [(uri, renderJSON, createdAt)]
            ).first
      else { continue }
      entries.append(entry.withPublicationId(publicationId).withReadState(isRead ?? false))
    }
    guard let membershipUpdatedAt else { return nil }
    let hasMore = entries.count > pageLimit
    let pageEntries = Array(entries.prefix(pageLimit))
    return AppViewFeedPage(
      response: AppViewEntryListResponse(
        entries: pageEntries,
        cursor: hasMore ? pageEntries.last.map {
          ThinAppViewCursor.encode(createdAt: $0.feedPositionAt, uri: $0.entryId)
        } : nil
      ),
      membershipUpdatedAt: membershipUpdatedAt,
      databaseDurationMilliseconds: Date().timeIntervalSince(databaseStartedAt) * 1_000
    )
  }

  public func hasViewerFeedProjection(viewerDid: String) async throws -> Bool {
    let rows = try await pool.query(
      """
      SELECT 1 FROM appview_viewer_feeds WHERE viewer_did = \(viewerDid)
      UNION ALL
      SELECT 1 FROM appview_publication_scopes WHERE viewer_did = \(viewerDid)
      LIMIT 1
      """,
      logger: logger
    )
    for try await _ in rows { return true }
    return false
  }

  public func publicationScopes(
    viewerDid: String,
    sectionKey: String
  ) async throws -> [AppViewPublicationScope] {
    let rows = try await pool.query(
      """
      SELECT viewer_did, publication_id, author_did, publication_at_uri,
             publication_scope_at_uris::text, publication_site_urls::text,
             scope_keys::text, section_keys::text, updated_at
      FROM appview_publication_scopes
      WHERE viewer_did = \(viewerDid)
        AND section_keys ? \(sectionKey)
      ORDER BY publication_id
      """,
      logger: logger
    )
    var scopes: [AppViewPublicationScope] = []
    for try await row in rows {
      if let scope = try Self.publicationScope(from: row) {
        scopes.append(scope)
      }
    }
    return scopes
  }

  public func listAggregateEntries(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewAggregatePageResult {
    try await listScopedEntries(
      viewerDid: viewerDid, scopes: scopes, filter: filter, cursor: cursor,
      limit: limit, deduplicateArticleURLs: true
    )
  }

  public func listUnreadEntriesForReadMutation(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    try await listScopedEntries(
      viewerDid: viewerDid, scopes: scopes, filter: .unread, cursor: cursor,
      limit: limit, deduplicateArticleURLs: false
    ).response
  }

  private func listScopedEntries(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int,
    deduplicateArticleURLs: Bool
  ) async throws -> AppViewAggregatePageResult {
    let startedAt = Date()
    let pageLimit = max(1, min(limit, 100))
    let batchSize = max(100, min(1_000, pageLimit * 4))
    let sortedScopes = scopes.sorted { $0.publicationId < $1.publicationId }
    guard !sortedScopes.isEmpty else {
      return AppViewAggregatePageResult(
        response: AppViewEntryListResponse(entries: [], cursor: nil),
        diagnostics: AppViewAggregatePageDiagnostics(
          rowsScanned: 0,
          rowsReturned: 0,
          duplicatesSuppressed: 0,
          queryDuration: Date().timeIntervalSince(startedAt)
        )
      )
    }

    var databaseCursor = cursor.flatMap(ThinAppViewCursor.decode)
    var matches: [AppViewEntryListItem] = []
    var rowsScanned = 0
    var duplicatesSuppressed = 0
    var databaseHasMore = false
    var lastScanned: (createdAt: Date, uri: String)?

    while matches.count <= pageLimit {
      let rows = try await fetchAggregateContentBatch(
        scopes: sortedScopes,
        cursor: databaseCursor,
        limit: batchSize
      )
      rowsScanned += rows.count
      databaseHasMore = rows.count == batchSize
      if let last = rows.last {
        lastScanned = (last.createdAt, last.uri)
      }

      let scopedEntries = rows.compactMap { row -> AppViewEntryListItem? in
        guard let scope = AggregateFeedQuerySupport.matchingScope(for: row, scopes: sortedScopes) else {
          return nil
        }
        return AggregateFeedQuerySupport.entry(from: row, publicationId: scope.publicationId)
      }
      let states = try await readStates(viewerDid: viewerDid, entries: scopedEntries)
      let filtered = AggregateFeedQuerySupport.filteredByReadState(
        scopedEntries,
        states: states,
        filter: filter
      )
      if deduplicateArticleURLs {
        let deduped = AggregateFeedQuerySupport.deduplicated(matches + filtered)
        matches = deduped.entries
        duplicatesSuppressed += deduped.duplicatesSuppressed
      } else {
        matches.append(contentsOf: filtered)
      }

      if matches.count > pageLimit || !databaseHasMore { break }
      guard let lastScanned else { break }
      databaseCursor = lastScanned
    }

    let response = AggregateFeedQuerySupport.response(
      matches: matches,
      pageLimit: pageLimit,
      lastScanned: lastScanned,
      databaseHasMore: databaseHasMore
    )
    return AppViewAggregatePageResult(
      response: response,
      diagnostics: AppViewAggregatePageDiagnostics(
        rowsScanned: rowsScanned,
        rowsReturned: response.entries.count,
        duplicatesSuppressed: duplicatesSuppressed,
        queryDuration: Date().timeIntervalSince(startedAt)
      )
    )
  }

  private func fetchAggregateContentBatch(
    scopes: [AppViewPublicationScope],
    cursor: (createdAt: Date, uri: String)?,
    limit: Int
  ) async throws -> [AggregateFeedDatabaseRow] {
    let authorDids = Array(Set(scopes.map(\.authorDid))).sorted()
    let unscopedAuthorDids = Array(Set(scopes.filter(\.scopeKeys.isEmpty).map(\.authorDid))).sorted()
    let scopeKeys = Array(Set(scopes.flatMap(\.scopeKeys))).sorted()
    guard !authorDids.isEmpty else { return [] }
    let now = Date()
    let rows: PostgresRowSequence
    if let cursor {
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.author_did, ci.publication_site, ci.created_at,
               COALESCE(ci.render_json->>'title', ''),
               ci.render_json->>'publishedAt',
               ci.render_json->>'summary',
               ci.render_json->>'thumbnailUrl',
               ci.render_json->>'articleUrl'
        FROM content_items ci
        WHERE ci.author_did = ANY(\(authorDids))
          AND ci.expires_at > \(now)
          AND (
            ci.author_did = ANY(\(unscopedAuthorDids))
            OR ci.publication_site = ANY(\(scopeKeys))
          )
          AND (
            ci.created_at < \(cursor.createdAt)
            OR (ci.created_at = \(cursor.createdAt) AND ci.uri < \(cursor.uri))
          )
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    } else {
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.author_did, ci.publication_site, ci.created_at,
               COALESCE(ci.render_json->>'title', ''),
               ci.render_json->>'publishedAt',
               ci.render_json->>'summary',
               ci.render_json->>'thumbnailUrl',
               ci.render_json->>'articleUrl'
        FROM content_items ci
        WHERE ci.author_did = ANY(\(authorDids))
          AND ci.expires_at > \(now)
          AND (
            ci.author_did = ANY(\(unscopedAuthorDids))
            OR ci.publication_site = ANY(\(scopeKeys))
          )
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    }

    var fetched: [AggregateFeedDatabaseRow] = []
    for try await row in rows {
      let (
        uri,
        authorDid,
        publicationSite,
        createdAt,
        title,
        publishedAt,
        summary,
        thumbnailUrl,
        articleUrl
      ) = try row.decode(
        (String, String, String?, Date, String, String?, String?, String?, String?).self
      )
      fetched.append(
        AggregateFeedDatabaseRow(
          uri: uri,
          authorDid: authorDid,
          publicationSite: publicationSite,
          createdAt: createdAt,
          title: title,
          publishedAt: publishedAt,
          summary: summary,
          thumbnailUrl: thumbnailUrl,
          articleUrl: articleUrl
        )
      )
    }
    return fetched
  }

  private func fetchSiteScopedContentBatch(
    viewerDid: String,
    authorDid: String,
    siteKeys: [String],
    filter: EntryListFilter,
    cursor: (createdAt: Date, uri: String)?,
    limit: Int,
    now: Date,
    readBoundary: ReadWatermarkBoundary?
  ) async throws -> [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] {
    let rows: PostgresRowSequence
    let unreadFloor = readBoundary?.createdAt ?? Date(timeIntervalSince1970: 0)
    let unreadFloorUri = readBoundary?.entryId
    let hasReadBoundary = readBoundary != nil
    let hasUnreadFloorUri = unreadFloorUri != nil
    switch (filter, cursor) {
    case (.all, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND ci.publication_site = ANY(\(siteKeys))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.unread, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND rm.subject_uri IS NULL
          AND (
            \(hasReadBoundary) = FALSE
            OR ci.created_at > \(unreadFloor)
            OR (\(hasUnreadFloorUri) = TRUE AND ci.created_at = \(unreadFloor) AND ci.uri > \(unreadFloorUri))
            OR uo.subject_uri IS NOT NULL
          )
          AND ci.publication_site = ANY(\(siteKeys))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.read, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND (
            rm.subject_uri IS NOT NULL
            OR (
              \(hasReadBoundary) = TRUE
              AND uo.subject_uri IS NULL
              AND (
                ci.created_at < \(unreadFloor)
                OR (ci.created_at = \(unreadFloor) AND (\(hasUnreadFloorUri) = FALSE OR ci.uri <= \(unreadFloorUri)))
              )
            )
          )
          AND ci.publication_site = ANY(\(siteKeys))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.all, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND ci.publication_site = ANY(\(siteKeys))
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.unread, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND rm.subject_uri IS NULL
          AND (
            \(hasReadBoundary) = FALSE
            OR ci.created_at > \(unreadFloor)
            OR (\(hasUnreadFloorUri) = TRUE AND ci.created_at = \(unreadFloor) AND ci.uri > \(unreadFloorUri))
            OR uo.subject_uri IS NOT NULL
          )
          AND ci.publication_site = ANY(\(siteKeys))
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.read, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND (
            rm.subject_uri IS NOT NULL
            OR (
              \(hasReadBoundary) = TRUE
              AND uo.subject_uri IS NULL
              AND (
                ci.created_at < \(unreadFloor)
                OR (ci.created_at = \(unreadFloor) AND (\(hasUnreadFloorUri) = FALSE OR ci.uri <= \(unreadFloorUri)))
              )
            )
          )
          AND ci.publication_site = ANY(\(siteKeys))
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    }

    var fetched: [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] = []
    for try await row in rows {
      let (uri, renderJSON, createdAt, publicationSite) = try row.decode(
        (String, String, Date, String?).self
      )
      fetched.append((uri, renderJSON, createdAt, publicationSite))
    }
    return fetched
  }

  private func fetchContentBatch(
    viewerDid: String,
    authorDid: String,
    filter: EntryListFilter,
    cursor: (createdAt: Date, uri: String)?,
    limit: Int,
    now: Date,
    readBoundary: ReadWatermarkBoundary?
  ) async throws -> [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] {
    let rows: PostgresRowSequence
    let unreadFloor = readBoundary?.createdAt ?? Date(timeIntervalSince1970: 0)
    let unreadFloorUri = readBoundary?.entryId
    let hasReadBoundary = readBoundary != nil
    let hasUnreadFloorUri = unreadFloorUri != nil
    switch (filter, cursor) {
    case (.all, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.unread, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
          AND (
            \(hasReadBoundary) = FALSE
            OR ci.created_at > \(unreadFloor)
            OR (\(hasUnreadFloorUri) = TRUE AND ci.created_at = \(unreadFloor) AND ci.uri > \(unreadFloorUri))
            OR uo.subject_uri IS NOT NULL
          )
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.read, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
          AND (
            rm.subject_uri IS NOT NULL
            OR (
              \(hasReadBoundary) = TRUE
              AND uo.subject_uri IS NULL
              AND (
                ci.created_at < \(unreadFloor)
                OR (ci.created_at = \(unreadFloor) AND (\(hasUnreadFloorUri) = FALSE OR ci.uri <= \(unreadFloorUri)))
              )
            )
          )
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.all, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.unread, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
          AND (
            \(hasReadBoundary) = FALSE
            OR ci.created_at > \(unreadFloor)
            OR (\(hasUnreadFloorUri) = TRUE AND ci.created_at = \(unreadFloor) AND ci.uri > \(unreadFloorUri))
            OR uo.subject_uri IS NOT NULL
          )
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.read, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
          AND (
            rm.subject_uri IS NOT NULL
            OR (
              \(hasReadBoundary) = TRUE
              AND uo.subject_uri IS NULL
              AND (
                ci.created_at < \(unreadFloor)
                OR (ci.created_at = \(unreadFloor) AND (\(hasUnreadFloorUri) = FALSE OR ci.uri <= \(unreadFloorUri)))
              )
            )
          )
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    }

    var fetched: [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] = []
    for try await row in rows {
      let (uri, renderJSON, createdAt, publicationSite) = try row.decode(
        (String, String, Date, String?).self
      )
      fetched.append((uri, renderJSON, createdAt, publicationSite))
    }
    return fetched
  }

  public func countUnreadEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> Int {
    let now = Date()
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )

    if !scoped {
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::int
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
        """,
        logger: logger
      )
      for try await row in rows {
        return try row.decode(Int.self)
      }
      return 0
    }

    let siteKeys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    if !siteKeys.isEmpty {
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::int
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND rm.subject_uri IS NULL
          AND ci.publication_site = ANY(\(siteKeys))
        """,
        logger: logger
      )
      for try await row in rows {
        return try row.decode(Int.self)
      }
      return 0
    }

    let rows = try await pool.query(
      """
      SELECT ci.publication_site
      FROM content_items ci
      LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
      WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
      """,
      logger: logger
    )
    var siteFields: [String?] = []
    for try await row in rows {
      let site: String? = try row.decode(String?.self)
      siteFields.append(site)
    }
    return ThinAppViewQuerySupport.countMatchingPublicationSites(
      siteFields: siteFields,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
  }

  public func countUnreadEntriesBatch(
    viewerDid: String,
    scopes: [PublicationUnreadScope]
  ) async throws -> [String: Int] {
    guard !scopes.isEmpty else { return [:] }

    let authorDids = Array(Set(scopes.map(\.authorDid)))
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.author_did, ci.publication_site, COUNT(*)::int
      FROM content_items ci
      LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
      WHERE ci.author_did = ANY(\(authorDids))
        AND ci.expires_at > \(now)
        AND rm.subject_uri IS NULL
      GROUP BY ci.author_did, ci.publication_site
      """,
      logger: logger
    )

    var unreadSiteCountsByAuthor: [String: [UnreadSiteCount]] = Dictionary(
      uniqueKeysWithValues: authorDids.map { ($0, []) }
    )
    for try await row in rows {
      let (authorDid, site, count): (String, String?, Int) = try row.decode((String, String?, Int).self)
      unreadSiteCountsByAuthor[authorDid, default: []].append(
        UnreadSiteCount(site: site, count: count)
      )
    }

    return ThinAppViewQuerySupport.batchUnreadCounts(
      scopes: scopes,
      unreadSiteCountsByAuthor: unreadSiteCountsByAuthor
    )
  }

  public func upsertPublicationScopes(_ scopes: [AppViewPublicationScope]) async throws {
    guard !scopes.isEmpty else { return }
    let scopesJSON = try Self.publicationScopesJSON(scopes)
    try await pool.query(Self.upsertPublicationScopesQuery(scopesJSON), logger: logger)
  }

  public func replacePublicationScopes(
    viewerDid: String,
    scopes: [AppViewPublicationScope]
  ) async throws {
    let scopesJSON = try Self.publicationScopesJSON(scopes)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM appview_publication_scopes WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
      if !scopes.isEmpty {
        try await connection.query(
          Self.upsertPublicationScopesQuery(scopesJSON),
          logger: logger
        )
      }
    }
  }

  public func upsertViewerFeedProjection(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    feeds: [AppViewViewerFeed],
    memberships: [AppViewFeedPublication]
  ) async throws {
    let scopesJSON = try Self.publicationScopesJSON(scopes)
    let feedsJSON = try Self.viewerFeedsJSON(feeds)
    let membershipsJSON = try Self.feedMembershipsJSON(memberships)
    try await pool.withTransaction(logger: logger) { connection in
      if !scopes.isEmpty {
        try await connection.query(Self.upsertPublicationScopesQuery(scopesJSON), logger: logger)
      }
      if !feeds.isEmpty {
        try await connection.query(Self.upsertViewerFeedsQuery(feedsJSON), logger: logger)
      }
      if !memberships.isEmpty {
        try await connection.query(
          Self.upsertFeedMembershipsQuery(membershipsJSON),
          logger: logger
        )
      }
    }
    _ = viewerDid
  }

  public func replaceViewerFeedProjection(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    feeds: [AppViewViewerFeed],
    memberships: [AppViewFeedPublication]
  ) async throws {
    let scopesJSON = try Self.publicationScopesJSON(scopes)
    let feedsJSON = try Self.viewerFeedsJSON(feeds)
    let membershipsJSON = try Self.feedMembershipsJSON(memberships)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM appview_feed_publications WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM appview_viewer_feeds WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM appview_publication_scopes WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
      if !scopes.isEmpty {
        try await connection.query(Self.upsertPublicationScopesQuery(scopesJSON), logger: logger)
      }
      if !feeds.isEmpty {
        try await connection.query(Self.upsertViewerFeedsQuery(feedsJSON), logger: logger)
      }
      if !memberships.isEmpty {
        try await connection.query(
          Self.upsertFeedMembershipsQuery(membershipsJSON),
          logger: logger
        )
      }
    }
  }

  public func fetchUnreadCounters(
    viewerDid: String,
    publicationIds: [String]?
  ) async throws -> [AppViewUnreadCounter] {
    let rows: PostgresRowSequence
    if let publicationIds, !publicationIds.isEmpty {
      rows = try await pool.query(
        """
        SELECT publication_id, unread_count, generation, accuracy, dirty, counted_at
        FROM appview_unread_counters
        WHERE viewer_did = \(viewerDid)
          AND publication_id = ANY(\(publicationIds))
        """,
        logger: logger
      )
    } else {
      rows = try await pool.query(
        """
        SELECT publication_id, unread_count, generation, accuracy, dirty, counted_at
        FROM appview_unread_counters
        WHERE viewer_did = \(viewerDid)
        """,
        logger: logger
      )
    }
    var counters: [AppViewUnreadCounter] = []
    for try await row in rows {
      if let counter = try Self.unreadCounter(from: row) {
        counters.append(counter)
      }
    }
    return counters
  }

  public func refreshUnreadCounters(
    viewerDid: String,
    scopes: [PublicationUnreadScope]
  ) async throws -> [AppViewUnreadCounter] {
    guard !scopes.isEmpty else { return [] }
    let exactCounts = try await countUnreadEntriesBatch(viewerDid: viewerDid, scopes: scopes)
    let boundaries = try await readBoundaries(
      viewerDid: viewerDid,
      publicationIds: scopes.map(\.publicationId)
    )
    let countedAt = Date()
    let generation = AppViewUnreadCounterSupport.generation(for: countedAt)
    var counters: [AppViewUnreadCounter] = []

    for scope in scopes {
      let count: Int
      if let boundary = boundaries[scope.publicationId] {
        count = try await countUnreadEntriesAfterBoundary(
          viewerDid: viewerDid,
          scope: scope,
          readBoundary: boundary
        )
      } else {
        count = exactCounts[scope.publicationId] ?? 0
      }
      let counter = AppViewUnreadCounter(
        publicationId: scope.publicationId,
        unreadCount: count,
        generation: generation,
        accuracy: .exact,
        dirty: false,
        countedAt: countedAt
      )
      try await upsertUnreadCounter(counter, viewerDid: viewerDid)
      counters.append(counter)
    }
    return counters
  }

  public func incrementUnreadCountersForContentItem(_ item: IndexedContentItem) async throws {
    let scopes = try await publicationScopes(authorDid: item.authorDid, viewerDid: nil)
      .filter {
        AppViewUnreadCounterSupport.contentMatchesScope(
          authorDid: item.authorDid,
          publicationSite: item.publicationSite,
          scope: $0
        )
      }
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Date()
    for scope in scopes {
      if let boundary = try await readBoundary(
        viewerDid: scope.viewerDid,
        publicationId: scope.publicationId
      ),
         boundary.contains(createdAt: item.createdAt, entryId: item.uri),
         !(try await hasUnreadOverride(viewerDid: scope.viewerDid, subjectUri: item.uri))
      {
        continue
      }
      let alreadyRead = try await hasReadMark(viewerDid: scope.viewerDid, subjectUri: item.uri)
      guard !alreadyRead else { continue }
      try await adjustUnreadCounter(
        viewerDid: scope.viewerDid,
        publicationId: scope.publicationId,
        delta: 1,
        generation: generation,
        countedAt: countedAt
      )
    }
  }

  public func markUnreadCountersDirtyForContent(authorDid: String, publicationSite: String?) async throws {
    let scopes = try await publicationScopes(authorDid: authorDid, viewerDid: nil)
      .filter {
        AppViewUnreadCounterSupport.contentMatchesScope(
          authorDid: authorDid,
          publicationSite: publicationSite,
          scope: $0
        )
      }
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Date()
    for scope in scopes {
      try await markUnreadCounterDirty(
        viewerDid: scope.viewerDid,
        publicationId: scope.publicationId,
        generation: generation,
        countedAt: countedAt
      )
    }
  }

  public func markUnreadCountersDirtyForAuthor(authorDid: String) async throws {
    let scopes = try await publicationScopes(authorDid: authorDid, viewerDid: nil)
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Date()
    for scope in scopes {
      try await markUnreadCounterDirty(
        viewerDid: scope.viewerDid,
        publicationId: scope.publicationId,
        generation: generation,
        countedAt: countedAt
      )
    }
  }

  public func adjustUnreadCountersForReadState(
    viewerDid: String,
    subjectUri: String,
    delta: Int
  ) async throws {
    guard delta != 0 else { return }
    guard let content = try await contentCounterFields(uri: subjectUri) else { return }
    let scopes = try await publicationScopes(authorDid: content.authorDid, viewerDid: viewerDid)
      .filter {
        AppViewUnreadCounterSupport.contentMatchesScope(
          authorDid: content.authorDid,
          publicationSite: content.publicationSite,
          scope: $0
        )
      }
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Date()
    for scope in scopes {
      try await adjustUnreadCounter(
        viewerDid: viewerDid,
        publicationId: scope.publicationId,
        delta: delta,
        generation: generation,
        countedAt: countedAt
      )
    }
  }

  public func markAllReadCounters(
    viewerDid: String,
    scopes: [PublicationUnreadScope],
    readAt: Date
  ) async throws -> (counters: [AppViewUnreadCounter], boundaries: [ReadWatermarkBoundary]) {
    let uniqueScopes = Dictionary(scopes.map { ($0.publicationId, $0) }, uniquingKeysWith: { first, _ in first })
      .values
      .sorted { $0.publicationId < $1.publicationId }
    guard !uniqueScopes.isEmpty else { return ([], []) }
    let generation = AppViewUnreadCounterSupport.generation(for: readAt)
    return try await pool.withTransaction(logger: logger) { connection in
      var counters: [AppViewUnreadCounter] = []
      var boundaries: [ReadWatermarkBoundary] = []
      for scope in uniqueScopes {
        // Two-key overload combines independent hashes of viewerDid/publicationId — avoids
        // concatenating them with a delimiter, which previously used a literal NUL byte
        // ("\u{0}") that Postgres text parameters can never contain (sqlState 22021:
        // "invalid byte sequence for encoding UTF8: 0x00"), failing this query on every call.
        let lockRows = try await connection.query(
          """
          SELECT pg_advisory_xact_lock(hashtext(\(viewerDid)), hashtext(\(scope.publicationId)))
          """,
          logger: logger
        )
        for try await _ in lockRows {}
        let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
          publicationAtUri: scope.publicationAtUri,
          publicationScopeAtUris: scope.publicationScopeAtUris,
          publicationSiteUrls: scope.publicationSiteUrls
        )
        let siteKeys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
          publicationAtUri: scope.publicationAtUri,
          publicationScopeAtUris: scope.publicationScopeAtUris,
          publicationSiteUrls: scope.publicationSiteUrls
        )
        var requested = ReadWatermarkBoundary(
          publicationId: scope.publicationId,
          createdAt: readAt,
          entryId: nil
        )
        if !scoped || !siteKeys.isEmpty {
          let rows: PostgresRowSequence
          if scoped {
            rows = try await connection.query(
              """
              SELECT uri, created_at
              FROM content_items
              WHERE author_did = \(scope.authorDid)
                AND created_at <= \(readAt)
                AND publication_site = ANY(\(siteKeys))
              ORDER BY created_at DESC, uri DESC
              LIMIT 1
              """,
              logger: logger
            )
          } else {
            rows = try await connection.query(
              """
              SELECT uri, created_at
              FROM content_items
              WHERE author_did = \(scope.authorDid) AND created_at <= \(readAt)
              ORDER BY created_at DESC, uri DESC
              LIMIT 1
              """,
              logger: logger
            )
          }
          for try await row in rows {
            let (uri, createdAt) = try row.decode((String, Date).self)
            requested = ReadWatermarkBoundary(
              publicationId: scope.publicationId,
              createdAt: createdAt,
              entryId: uri
            )
          }
        }
        let existingRows = try await connection.query(
          """
          SELECT read_floor_at, read_floor_uri
          FROM appview_publication_read_floors
          WHERE viewer_did = \(viewerDid) AND publication_id = \(scope.publicationId)
          FOR UPDATE
          """,
          logger: logger
        )
        var existing: ReadWatermarkBoundary?
        for try await row in existingRows {
          let (createdAt, entryId) = try row.decode((Date, String?).self)
          existing = ReadWatermarkBoundary(
            publicationId: scope.publicationId,
            createdAt: createdAt,
            entryId: entryId
          )
        }
        let confirmed = existing.map { requested.isAfter($0) ? requested : $0 } ?? requested
        let hasConfirmedEntryId = confirmed.entryId != nil
        try await connection.query(
          """
          INSERT INTO appview_publication_read_floors
            (viewer_did, publication_id, read_floor_at, read_floor_uri, generation, updated_at)
          VALUES
            (\(viewerDid), \(scope.publicationId), \(confirmed.createdAt), \(confirmed.entryId), \(generation), \(readAt))
          ON CONFLICT (viewer_did, publication_id)
          DO UPDATE SET
            read_floor_at = EXCLUDED.read_floor_at,
            read_floor_uri = EXCLUDED.read_floor_uri,
            generation = EXCLUDED.generation,
            updated_at = EXCLUDED.updated_at
          """,
          logger: logger
        )
        let overrideRows = try await connection.query(
          """
          SELECT uo.subject_uri, ci.created_at, ci.publication_site
          FROM appview_unread_overrides uo
          INNER JOIN content_items ci ON ci.uri = uo.subject_uri
          WHERE uo.viewer_did = \(viewerDid)
            AND uo.created_at <= \(readAt)
            AND ci.author_did = \(scope.authorDid)
          """,
          logger: logger
        )
        var coveredOverrides: [String] = []
        for try await row in overrideRows {
          let (subjectUri, createdAt, publicationSite) = try row.decode(
            (String, Date, String?).self
          )
          guard confirmed.contains(createdAt: createdAt, entryId: subjectUri) else { continue }
          guard ThinAppViewQuerySupport.publicationSiteMatches(
            siteField: publicationSite,
            publicationAtUri: scope.publicationAtUri,
            publicationScopeAtUris: scope.publicationScopeAtUris,
            publicationSiteUrls: scope.publicationSiteUrls
          ) else {
            continue
          }
          coveredOverrides.append(subjectUri)
        }
        if !coveredOverrides.isEmpty {
          try await connection.query(
            """
            DELETE FROM appview_unread_overrides
            WHERE viewer_did = \(viewerDid) AND subject_uri = ANY(\(coveredOverrides))
            """,
            logger: logger
          )
        }
        var unreadCount = 0
        if !scoped || !siteKeys.isEmpty {
          let now = Date()
          let unreadRows: PostgresRowSequence
          if scoped {
            unreadRows = try await connection.query(
              """
              SELECT COUNT(*)::int
              FROM content_items ci
              LEFT JOIN read_marks rm
                ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
              LEFT JOIN appview_unread_overrides uo
                ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
              WHERE ci.author_did = \(scope.authorDid)
                AND ci.expires_at > \(now)
                AND (
                  ci.created_at > \(confirmed.createdAt)
                  OR (
                    \(hasConfirmedEntryId) = TRUE
                    AND ci.created_at = \(confirmed.createdAt)
                    AND ci.uri > \(confirmed.entryId)
                  )
                  OR uo.subject_uri IS NOT NULL
                )
                AND ci.publication_site = ANY(\(siteKeys))
                AND rm.subject_uri IS NULL
              """,
              logger: logger
            )
          } else {
            unreadRows = try await connection.query(
              """
              SELECT COUNT(*)::int
              FROM content_items ci
              LEFT JOIN read_marks rm
                ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
              LEFT JOIN appview_unread_overrides uo
                ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
              WHERE ci.author_did = \(scope.authorDid)
                AND ci.expires_at > \(now)
                AND (
                  ci.created_at > \(confirmed.createdAt)
                  OR (
                    \(hasConfirmedEntryId) = TRUE
                    AND ci.created_at = \(confirmed.createdAt)
                    AND ci.uri > \(confirmed.entryId)
                  )
                  OR uo.subject_uri IS NOT NULL
                )
                AND rm.subject_uri IS NULL
              """,
              logger: logger
            )
          }
          for try await row in unreadRows {
            unreadCount = try row.decode(Int.self)
          }
        }
        let counter = AppViewUnreadCounter(
          publicationId: scope.publicationId,
          unreadCount: unreadCount,
          generation: generation,
          accuracy: .exact,
          dirty: false,
          countedAt: readAt
        )
        try await connection.query(
          """
          INSERT INTO appview_unread_counters
            (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
          VALUES
            (\(viewerDid), \(scope.publicationId), \(unreadCount), \(generation), \(counter.accuracy.rawValue), FALSE, \(readAt))
          ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
            unread_count = EXCLUDED.unread_count,
            generation = EXCLUDED.generation,
            accuracy = EXCLUDED.accuracy,
            dirty = FALSE,
            counted_at = EXCLUDED.counted_at
          """,
          logger: logger
        )
        counters.append(counter)
        boundaries.append(confirmed)
      }
      // Overrides whose content_items row has since TTL-expired (deleteExpiredContent)
      // can never be matched by the per-scope INNER JOIN above, so mark-all-read could
      // never clear them. They are dead data — every feed/read-state query joins
      // content_items, so an orphan cannot surface on its own — but RSS entries are
      // re-indexed under the same deterministic `rssentry:` URI, which resurrects the
      // stale override and makes an already-read article pop back as unread.
      try await connection.query(
        """
        DELETE FROM appview_unread_overrides uo
        WHERE uo.viewer_did = \(viewerDid)
          AND uo.created_at <= \(readAt)
          AND NOT EXISTS (
            SELECT 1 FROM content_items ci WHERE ci.uri = uo.subject_uri
          )
        """,
        logger: logger
      )
      return (counters, boundaries)
    }
  }

  public func deleteExpiredContent(before: Date, batchSize: Int) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM content_items
        WHERE expires_at <= \(before)
        ORDER BY expires_at, uri
        LIMIT \(batchSize)
      )
      DELETE FROM content_items AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING target.uri
      """,
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }

  public func deleteExpiredReadMarks(before: Date, batchSize: Int) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM read_marks
        WHERE created_at <= \(before)
        ORDER BY created_at, viewer_did, subject_uri
        LIMIT \(batchSize)
      )
      DELETE FROM read_marks AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING target.subject_uri
      """,
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }

  public func deleteExpiredTapEventReceipts(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM appview_tap_event_receipts
        WHERE environment = \(environment) AND expires_at <= \(before)
        ORDER BY expires_at, event_id
        LIMIT \(batchSize)
      )
      DELETE FROM appview_tap_event_receipts AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING 1
      """,
      logger: logger
    )
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func deleteExpiredProjectionRepairs(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM appview_projection_repair_outbox
        WHERE environment = \(environment) AND status = 'failed' AND expires_at <= \(before)
        ORDER BY expires_at, id
        LIMIT \(batchSize)
      )
      DELETE FROM appview_projection_repair_outbox AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING 1
      """,
      logger: logger
    )
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func desiredTapRepositoryScope(limit: Int) async throws -> TapDesiredRepositoryScope {
    let limit = max(1, min(limit, 10_000))
    let scanBatchSize = 500
    var repoDids: [String] = []
    var after = ""
    while repoDids.count <= limit {
      let rows = try await pool.query(
        """
        SELECT DISTINCT author_did
        FROM appview_publication_scopes
        WHERE author_did > \(after)
        ORDER BY author_did
        LIMIT \(scanBatchSize)
        """,
        logger: logger
      )
      var page: [String] = []
      for try await row in rows {
        page.append(try row.decode(String.self))
      }
      guard let last = page.last else { break }
      repoDids.append(contentsOf: page.filter(ATProtoRepositoryDIDValidator.isValid))
      after = last
      if page.count < scanBatchSize { break }
    }
    return TapDesiredRepositoryScope(
      repoDids: Array(repoDids.prefix(limit)),
      truncated: repoDids.count > limit
    )
  }

  public func registeredTapRepositoryDids(environment: String) async throws -> [String] {
    let rows = try await pool.query(
      """
      SELECT repo_did
      FROM appview_tap_repository_registrations
      WHERE environment = \(environment) AND is_registered = TRUE
      ORDER BY repo_did
      """,
      logger: logger
    )
    var repoDids: [String] = []
    for try await row in rows {
      repoDids.append(try row.decode(String.self))
    }
    return repoDids
  }

  public func markTapRepositoriesRegistered(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws {
    guard !repoDids.isEmpty else { return }
    try await pool.withTransaction(logger: logger) { connection in
      for repoDid in repoDids {
        try await connection.query(
          """
          INSERT INTO appview_tap_repository_registrations
            (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
          VALUES (\(environment), \(repoDid), TRUE, \(at), NULL, \(at))
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            is_registered = TRUE,
            registered_at = EXCLUDED.registered_at,
            removed_at = NULL,
            updated_at = EXCLUDED.updated_at
          """,
          logger: logger
        )
      }
    }
  }

  public func markTapRepositoriesRemoved(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws {
    guard !repoDids.isEmpty else { return }
    try await pool.withTransaction(logger: logger) { connection in
      for repoDid in repoDids {
        try await connection.query(
          """
          INSERT INTO appview_tap_repository_registrations
            (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
          VALUES (\(environment), \(repoDid), FALSE, NULL, \(at), \(at))
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            is_registered = FALSE,
            removed_at = EXCLUDED.removed_at,
            updated_at = EXCLUDED.updated_at
          """,
          logger: logger
        )
      }
    }
  }

  public func recordIngestionCheckpoint(
    environment: String,
    source: String,
    repoDid: String,
    collection: String,
    cursor: String?,
    eventTime: Date?,
    observedAt: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_checkpoints
        (environment, source, repo_did, collection, cursor, event_time, observed_at)
      VALUES
        (\(environment), \(source), \(repoDid), \(collection), \(cursor), \(eventTime), \(observedAt))
      ON CONFLICT (environment, source, repo_did, collection)
      DO UPDATE SET
        cursor = EXCLUDED.cursor,
        event_time = EXCLUDED.event_time,
        observed_at = EXCLUDED.observed_at
      """,
      logger: logger
    )
  }

  public func fetchTapRepositorySyncState(
    environment: String,
    repoDid: String
  ) async throws -> TapRepositorySyncState? {
    let rows = try await pool.query(
      """
      SELECT repo_rev, account_status, pds_base, last_event_id, last_event_live,
             parity_status, matched_event_count, mismatched_event_count,
             last_mismatch, last_indexed_at, last_validated_at, updated_at
      FROM appview_tap_repo_state
      WHERE environment = \(environment)
        AND repo_did = \(repoDid)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let decoded = try row.decode(
        (
          String?, String, String?, Int64?, Bool, String, Int64, Int64,
          String?, Date?, Date?, Date
        ).self
      )
      guard
        let accountStatus = TapAccountStatus(rawValue: decoded.1),
        let parityStatus = TapParityStatus(rawValue: decoded.5)
      else { return nil }
      return TapRepositorySyncState(
        environment: environment,
        repoDid: repoDid,
        repoRev: decoded.0,
        accountStatus: accountStatus,
        pdsBase: decoded.2,
        lastEventId: decoded.3,
        lastEventLive: decoded.4,
        parityStatus: parityStatus,
        matchedEventCount: decoded.6,
        mismatchedEventCount: decoded.7,
        lastMismatch: decoded.8,
        lastIndexedAt: decoded.9,
        lastValidatedAt: decoded.10,
        updatedAt: decoded.11
      )
    }
    return nil
  }

  public func upsertTapRepositorySyncState(_ state: TapRepositorySyncState) async throws {
    try await pool.query(
      """
      INSERT INTO appview_tap_repo_state
        (environment, repo_did, repo_rev, account_status, pds_base,
         last_event_id, last_event_live, parity_status, matched_event_count,
         mismatched_event_count, last_mismatch, last_indexed_at,
         last_validated_at, updated_at)
      VALUES
        (\(state.environment), \(state.repoDid), \(state.repoRev),
         \(state.accountStatus.rawValue), \(state.pdsBase), \(state.lastEventId),
         \(state.lastEventLive), \(state.parityStatus.rawValue),
         \(state.matchedEventCount), \(state.mismatchedEventCount),
         \(state.lastMismatch), \(state.lastIndexedAt), \(state.lastValidatedAt),
         \(state.updatedAt))
      ON CONFLICT (environment, repo_did)
      DO UPDATE SET
        repo_rev = EXCLUDED.repo_rev,
        account_status = EXCLUDED.account_status,
        pds_base = EXCLUDED.pds_base,
        last_event_id = EXCLUDED.last_event_id,
        last_event_live = EXCLUDED.last_event_live,
        parity_status = EXCLUDED.parity_status,
        matched_event_count = EXCLUDED.matched_event_count,
        mismatched_event_count = EXCLUDED.mismatched_event_count,
        last_mismatch = EXCLUDED.last_mismatch,
        last_indexed_at = EXCLUDED.last_indexed_at,
        last_validated_at = EXCLUDED.last_validated_at,
        updated_at = EXCLUDED.updated_at
      """,
      logger: logger
    )
  }

  public func hasProcessedTapEvent(environment: String, eventId: Int64) async throws -> Bool {
    let rows = try await pool.query(
      """
      SELECT EXISTS(
        SELECT 1 FROM appview_tap_event_receipts
        WHERE environment = \(environment) AND event_id = \(eventId)
      )
      """,
      logger: logger
    )
    for try await row in rows { return try row.decode(Bool.self) }
    return false
  }

  public func commitTapEvent(
    state: TapRepositorySyncState,
    eventId: Int64,
    eventType: String,
    parityEvidence: TapParityEventEvidence?,
    processedAt: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO appview_tap_repo_state
          (environment, repo_did, repo_rev, account_status, pds_base,
           last_event_id, last_event_live, parity_status, matched_event_count,
           mismatched_event_count, last_mismatch, last_indexed_at,
           last_validated_at, updated_at)
        VALUES
          (\(state.environment), \(state.repoDid), \(state.repoRev),
           \(state.accountStatus.rawValue), \(state.pdsBase), \(state.lastEventId),
           \(state.lastEventLive), \(state.parityStatus.rawValue),
           \(state.matchedEventCount), \(state.mismatchedEventCount),
           \(state.lastMismatch), \(state.lastIndexedAt), \(state.lastValidatedAt),
           \(state.updatedAt))
        ON CONFLICT (environment, repo_did)
        DO UPDATE SET
          repo_rev = EXCLUDED.repo_rev,
          account_status = EXCLUDED.account_status,
          pds_base = EXCLUDED.pds_base,
          last_event_id = EXCLUDED.last_event_id,
          last_event_live = EXCLUDED.last_event_live,
          parity_status = EXCLUDED.parity_status,
          matched_event_count = EXCLUDED.matched_event_count,
          mismatched_event_count = EXCLUDED.mismatched_event_count,
          last_mismatch = EXCLUDED.last_mismatch,
          last_indexed_at = EXCLUDED.last_indexed_at,
          last_validated_at = EXCLUDED.last_validated_at,
          updated_at = EXCLUDED.updated_at
        """,
        logger: logger
      )
      let expiresAt = processedAt.addingTimeInterval(30 * 86_400)
      try await connection.query(
        """
        INSERT INTO appview_tap_event_receipts
          (environment, event_id, repo_did, event_type, processed_at, expires_at)
        VALUES
          (\(state.environment), \(eventId), \(state.repoDid), \(eventType),
           \(processedAt), \(expiresAt))
        ON CONFLICT (environment, event_id) DO NOTHING
        """,
        logger: logger
      )
      if let parityEvidence {
        if let mismatchKind = parityEvidence.mismatchKind {
          try await connection.query(
            """
            INSERT INTO appview_tap_parity_discrepancies
              (environment, event_id, repo_did, uri, collection, mismatch_kind,
               expected_cid, observed_cid, status, opened_at)
            VALUES
              (\(state.environment), \(eventId), \(state.repoDid), \(parityEvidence.uri),
               \(parityEvidence.collection), \(mismatchKind), \(parityEvidence.expectedCid),
               \(parityEvidence.observedCid), 'open', \(processedAt))
            ON CONFLICT (environment, event_id) DO NOTHING
            """,
            logger: logger
          )
        } else {
          try await connection.query(
            """
            UPDATE appview_tap_parity_discrepancies
            SET status = 'resolved', resolved_at = \(processedAt), resolution_event_id = \(eventId)
            WHERE environment = \(state.environment) AND repo_did = \(state.repoDid)
              AND uri = \(parityEvidence.uri) AND status = 'open'
            """,
            logger: logger
          )
        }
        let countRows = try await connection.query(
          """
          SELECT COUNT(*)::bigint FROM appview_tap_parity_discrepancies
          WHERE environment = \(state.environment) AND repo_did = \(state.repoDid)
            AND status = 'open'
          """,
          logger: logger
        )
        var openCount: Int64 = 0
        for try await row in countRows { openCount = try row.decode(Int64.self) }
        let aggregateStatus = openCount == 0 ? TapParityStatus.matched : .mismatch
        try await connection.query(
          """
          UPDATE appview_tap_repo_state
          SET parity_status = \(aggregateStatus.rawValue),
              last_mismatch = CASE WHEN \(openCount) = 0 THEN NULL ELSE last_mismatch END
          WHERE environment = \(state.environment) AND repo_did = \(state.repoDid)
          """,
          logger: logger
        )
      }
    }
  }

  public func listTapParityDiscrepancies(
    environment: String,
    repoDid: String
  ) async throws -> [TapParityDiscrepancy] {
    let rows = try await pool.query(
      """
      SELECT event_id, uri, collection, mismatch_kind, expected_cid, observed_cid,
             status, opened_at, resolved_at, resolution_event_id
      FROM appview_tap_parity_discrepancies
      WHERE environment = \(environment) AND repo_did = \(repoDid)
      ORDER BY event_id
      """,
      logger: logger
    )
    var discrepancies: [TapParityDiscrepancy] = []
    for try await row in rows {
      let value = try row.decode(
        (Int64, String, String, String, String?, String?, String, Date, Date?, Int64?).self
      )
      guard let status = TapParityDiscrepancyStatus(rawValue: value.6) else { continue }
      discrepancies.append(
        TapParityDiscrepancy(
          environment: environment,
          eventId: value.0,
          repoDid: repoDid,
          uri: value.1,
          collection: value.2,
          mismatchKind: value.3,
          expectedCid: value.4,
          observedCid: value.5,
          status: status,
          openedAt: value.7,
          resolvedAt: value.8,
          resolutionEventId: value.9
        )
      )
    }
    return discrepancies
  }

  public func applyTapContentMutation(
    _ mutation: TapContentMutation,
    environment: String,
    eventId: Int64,
    repoRev: String,
    eventTime: Date,
    observedAt: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let publicationSite: String?
      let action: String
      switch mutation {
      case .upsert(let item):
        publicationSite = item.publicationSite
        action = "upsert"
        let renderJSON = try item.render.encodedJSON()
        try await connection.query(
          """
          INSERT INTO content_items
            (uri, cid, author_did, collection, created_at, indexed_at,
             publication_site, render_json, expires_at)
          VALUES
            (\(item.uri), \(item.cid), \(item.authorDid), \(item.collection),
             \(item.createdAt), \(item.indexedAt), \(item.publicationSite),
             \(renderJSON)::jsonb, \(item.expiresAt))
          ON CONFLICT (uri) DO UPDATE SET
            cid = EXCLUDED.cid,
            author_did = EXCLUDED.author_did,
            collection = EXCLUDED.collection,
            created_at = EXCLUDED.created_at,
            indexed_at = EXCLUDED.indexed_at,
            publication_site = EXCLUDED.publication_site,
            render_json = EXCLUDED.render_json,
            expires_at = EXCLUDED.expires_at
          """,
          logger: logger
        )
      case .delete(let uri, _, _):
        var existingSite: String?
        let rows = try await connection.query(
          "SELECT publication_site FROM content_items WHERE uri = \(uri) LIMIT 1",
          logger: logger
        )
        for try await row in rows {
          existingSite = try row.decode(String?.self)
        }
        publicationSite = existingSite
        action = "delete"
        try await connection.query(
          "DELETE FROM content_items WHERE uri = \(uri)",
          logger: logger
        )
      }

      try await connection.query(
        """
        INSERT INTO appview_ingestion_checkpoints
          (environment, source, repo_did, collection, cursor, event_time, observed_at)
        VALUES
          (\(environment), 'tap', \(mutation.authorDid), \(mutation.collection), \(String(eventId)),
           \(eventTime), \(observedAt))
        ON CONFLICT (environment, source, repo_did, collection) DO UPDATE SET
          cursor = EXCLUDED.cursor,
          event_time = EXCLUDED.event_time,
          observed_at = EXCLUDED.observed_at
        """,
        logger: logger
      )

      let repairId = "\(environment):\(eventId)"
      let expiresAt = observedAt.addingTimeInterval(30 * 86_400)
      try await connection.query(
        """
        INSERT INTO appview_projection_repair_outbox
          (id, environment, event_id, uri, author_did, publication_site, action,
           status, attempts, next_attempt_at, created_at, updated_at, expires_at)
        VALUES
          (\(repairId), \(environment), \(eventId), \(mutation.uri),
           \(mutation.authorDid), \(publicationSite), \(action), 'queued', 0,
           \(observedAt), \(observedAt), \(observedAt), \(expiresAt))
        ON CONFLICT (environment, event_id) DO NOTHING
        """,
        logger: logger
      )
      _ = repoRev
    }
  }

  public func projectionRepairBacklog(
    environment: String,
    at: Date
  ) async throws -> AppViewProjectionRepairBacklogSnapshot {
    let rows = try await pool.query(
      """
      SELECT
        COUNT(*) FILTER (WHERE status = 'queued')::bigint,
        COUNT(*) FILTER (WHERE status = 'running')::bigint,
        COUNT(*) FILTER (WHERE status = 'failed')::bigint,
        MIN(created_at) FILTER (WHERE status IN ('queued', 'running', 'failed'))
      FROM appview_projection_repair_outbox
      WHERE environment = \(environment)
      """,
      logger: logger
    )
    for try await row in rows {
      let decoded = try row.decode((Int64, Int64, Int64, Date?).self)
      guard let queuedCount = Int(exactly: decoded.0),
        let runningCount = Int(exactly: decoded.1),
        let failedCount = Int(exactly: decoded.2)
      else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      let hasActionableRepairs = queuedCount > 0 || runningCount > 0 || failedCount > 0
      guard queuedCount >= 0, runningCount >= 0, failedCount >= 0 else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      if hasActionableRepairs {
        guard let oldestActionableAt = decoded.3, oldestActionableAt <= at else {
          throw AppViewProjectionRepairError.invalidBacklogEvidence
        }
      } else if decoded.3 != nil {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      return AppViewProjectionRepairBacklogSnapshot(
        environment: environment,
        queuedCount: queuedCount,
        runningCount: runningCount,
        failedCount: failedCount,
        oldestActionableAt: decoded.3,
        oldestActionableAgeSeconds: decoded.3.map { at.timeIntervalSince($0) },
        observedAt: at
      )
    }
    throw AppViewProjectionRepairError.invalidBacklogEvidence
  }

  public func claimProjectionRepair(
    environment: String,
    workerId: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> AppViewProjectionRepair? {
    let rows = try await pool.query(
      """
      WITH candidate AS (
        SELECT id
        FROM appview_projection_repair_outbox
        WHERE environment = \(environment)
          AND ((status = 'queued' AND next_attempt_at <= \(at))
            OR (status = 'running' AND lease_until <= \(at)))
        ORDER BY created_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1
      )
      UPDATE appview_projection_repair_outbox AS repair
      SET status = 'running', lease_owner = \(workerId), lease_until = \(leaseUntil),
          updated_at = \(at)
      FROM candidate
      WHERE repair.environment = \(environment) AND repair.id = candidate.id
      RETURNING repair.id, repair.environment, repair.event_id, repair.uri,
                repair.author_did, repair.publication_site, repair.action, repair.attempts
      """,
      logger: logger
    )
    for try await row in rows {
      let decoded = try row.decode(
        (String, String, Int64, String, String, String?, String, Int).self
      )
      return AppViewProjectionRepair(
        id: decoded.0,
        environment: decoded.1,
        eventId: decoded.2,
        uri: decoded.3,
        authorDid: decoded.4,
        publicationSite: decoded.5,
        action: decoded.6,
        attempts: decoded.7,
        leaseOwner: workerId,
        leaseUntil: leaseUntil
      )
    }
    return nil
  }

  public func completeProjectionRepair(
    environment: String,
    id: String,
    workerId: String
  ) async throws {
    let rows = try await pool.query(
      """
      DELETE FROM appview_projection_repair_outbox
      WHERE environment = \(environment) AND id = \(id)
        AND status = 'running' AND lease_owner = \(workerId)
      RETURNING 1
      """,
      logger: logger
    )
    var deleted = false
    for try await _ in rows { deleted = true }
    guard deleted else { throw AppViewProjectionRepairError.staleLease }
  }

  public func failProjectionRepair(
    environment: String,
    id: String,
    workerId: String,
    errorCategory: String,
    retryAt: Date,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_projection_repair_outbox
      SET attempts = attempts + 1,
          status = CASE WHEN attempts + 1 >= 5 THEN 'failed' ELSE 'queued' END,
          lease_owner = NULL,
          lease_until = NULL,
          next_attempt_at = \(retryAt),
          last_error = \(errorCategory),
          updated_at = \(at)
      WHERE environment = \(environment) AND id = \(id)
        AND status = 'running' AND lease_owner = \(workerId)
      RETURNING 1
      """,
      logger: logger
    )
    var updated = false
    for try await _ in rows { updated = true }
    guard updated else { throw AppViewProjectionRepairError.staleLease }
  }

  public func listAuthorDidsForProactiveBackfill(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 500))
    let rows = try await pool.query(
      """
      SELECT author_did
      FROM content_items
      WHERE author_did LIKE 'did:%' AND author_did NOT LIKE 'did:web:%'
      GROUP BY author_did
      ORDER BY MAX(indexed_at) ASC
      LIMIT \(capped)
      """,
      logger: logger
    )
    var authorDids: [String] = []
    for try await row in rows {
      let did: String = try row.decode(String.self)
      authorDids.append(did)
    }
    return authorDids
  }

  public func listRssPublicationSites(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 200))
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT publication_site
      FROM content_items
      WHERE author_did = \(RssFeedLexicons.rssAuthorDid)
        AND publication_site IS NOT NULL
        AND expires_at > \(now)
      GROUP BY publication_site
      ORDER BY MIN(indexed_at) ASC
      LIMIT \(capped)
      """,
      logger: logger
    )
    var sites: [String] = []
    for try await row in rows {
      let site: String = try row.decode(String.self)
      sites.append(site)
    }
    return sites
  }

  public func fetchRssFeedMetadata(normalizedFeedUrl: String) async throws -> RssFeedFetchMetadata? {
    let rows = try await pool.query(
      """
      SELECT etag, last_modified, last_poll_at, backoff_until, consecutive_error_count
      FROM rss_feed_fetch_metadata
      WHERE feed_url = \(normalizedFeedUrl)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (etag, lastModified, lastPollAt, backoffUntil, consecutiveErrorCount) = try row.decode(
        (String?, String?, Date?, Date?, Int).self
      )
      return RssFeedFetchMetadata(
        normalizedFeedUrl: normalizedFeedUrl,
        etag: etag,
        lastModified: lastModified,
        lastPollAt: lastPollAt,
        backoffUntil: backoffUntil,
        consecutiveErrorCount: consecutiveErrorCount
      )
    }
    return nil
  }

  public func storeRssFeedMetadata(_ metadata: RssFeedFetchMetadata) async throws {
    try await pool.query(
      """
      INSERT INTO rss_feed_fetch_metadata
        (feed_url, etag, last_modified, last_poll_at, backoff_until, consecutive_error_count)
      VALUES
        (\(metadata.normalizedFeedUrl), \(metadata.etag), \(metadata.lastModified), \(metadata.lastPollAt), \(metadata.backoffUntil), \(metadata.consecutiveErrorCount))
      ON CONFLICT (feed_url)
      DO UPDATE SET
        etag = EXCLUDED.etag,
        last_modified = EXCLUDED.last_modified,
        last_poll_at = EXCLUDED.last_poll_at,
        backoff_until = EXCLUDED.backoff_until,
        consecutive_error_count = EXCLUDED.consecutive_error_count
      """,
      logger: logger
    )
  }

  private func publicationScopes(
    authorDid: String,
    viewerDid: String?
  ) async throws -> [AppViewPublicationScope] {
    let rows: PostgresRowSequence
    if let viewerDid {
      rows = try await pool.query(
        """
        SELECT viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris::text, publication_site_urls::text,
               scope_keys::text, section_keys::text, updated_at
        FROM appview_publication_scopes
        WHERE author_did = \(authorDid)
          AND viewer_did = \(viewerDid)
        """,
        logger: logger
      )
    } else {
      rows = try await pool.query(
        """
        SELECT viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris::text, publication_site_urls::text,
               scope_keys::text, section_keys::text, updated_at
        FROM appview_publication_scopes
        WHERE author_did = \(authorDid)
        """,
        logger: logger
      )
    }
    var scopes: [AppViewPublicationScope] = []
    for try await row in rows {
      if let scope = try Self.publicationScope(from: row) {
        scopes.append(scope)
      }
    }
    return scopes
  }

  private func readBoundaries(
    viewerDid: String,
    publicationIds: [String]
  ) async throws -> [String: ReadWatermarkBoundary] {
    let uniqueIds = Array(Set(publicationIds)).sorted()
    guard !uniqueIds.isEmpty else { return [:] }
    let rows = try await pool.query(
      """
      SELECT publication_id, read_floor_at, read_floor_uri
      FROM appview_publication_read_floors
      WHERE viewer_did = \(viewerDid)
        AND publication_id = ANY(\(uniqueIds))
      """,
      logger: logger
    )
    var boundaries: [String: ReadWatermarkBoundary] = [:]
    for try await row in rows {
      let (publicationId, createdAt, entryId) = try row.decode(
        (String, Date, String?).self
      )
      boundaries[publicationId] = ReadWatermarkBoundary(
        publicationId: publicationId,
        createdAt: createdAt,
        entryId: entryId
      )
    }
    return boundaries
  }

  public func readBoundary(
    viewerDid: String,
    publicationId: String
  ) async throws -> ReadWatermarkBoundary? {
    let rows = try await pool.query(
      """
      SELECT read_floor_at, read_floor_uri
      FROM appview_publication_read_floors
      WHERE viewer_did = \(viewerDid)
        AND publication_id = \(publicationId)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (createdAt, entryId) = try row.decode((Date, String?).self)
      return ReadWatermarkBoundary(
        publicationId: publicationId,
        createdAt: createdAt,
        entryId: entryId
      )
    }
    return nil
  }

  private func countUnreadEntriesAfterBoundary(
    viewerDid: String,
    scope: PublicationUnreadScope,
    readBoundary: ReadWatermarkBoundary
  ) async throws -> Int {
    let now = Date()
    let hasReadBoundaryEntryId = readBoundary.entryId != nil
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: scope.publicationAtUri,
      publicationScopeAtUris: scope.publicationScopeAtUris,
      publicationSiteUrls: scope.publicationSiteUrls
    )
    let siteKeys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
      publicationAtUri: scope.publicationAtUri,
      publicationScopeAtUris: scope.publicationScopeAtUris,
      publicationSiteUrls: scope.publicationSiteUrls
    )
    if scoped, !siteKeys.isEmpty {
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::int
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
        WHERE ci.author_did = \(scope.authorDid)
          AND ci.expires_at > \(now)
          AND (
            ci.created_at > \(readBoundary.createdAt)
            OR (
              \(hasReadBoundaryEntryId) = TRUE
              AND ci.created_at = \(readBoundary.createdAt)
              AND ci.uri > \(readBoundary.entryId)
            )
            OR uo.subject_uri IS NOT NULL
          )
          AND ci.publication_site = ANY(\(siteKeys))
          AND rm.subject_uri IS NULL
        """,
        logger: logger
      )
      for try await row in rows {
        return try row.decode(Int.self)
      }
      return 0
    }

    let rows = try await pool.query(
      """
      SELECT ci.publication_site
      FROM content_items ci
      LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
      LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewerDid) AND uo.subject_uri = ci.uri
      WHERE ci.author_did = \(scope.authorDid)
        AND ci.expires_at > \(now)
        AND (
          ci.created_at > \(readBoundary.createdAt)
          OR (
            \(hasReadBoundaryEntryId) = TRUE
            AND ci.created_at = \(readBoundary.createdAt)
            AND ci.uri > \(readBoundary.entryId)
          )
          OR uo.subject_uri IS NOT NULL
        )
        AND rm.subject_uri IS NULL
      """,
      logger: logger
    )
    var siteFields: [String?] = []
    for try await row in rows {
      let site: String? = try row.decode(String?.self)
      siteFields.append(site)
    }
    return scoped
      ? ThinAppViewQuerySupport.countMatchingPublicationSites(
        siteFields: siteFields,
        publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls
      )
      : siteFields.count
  }

  private func hasUnreadOverride(
    viewerDid: String,
    subjectUri: String
  ) async throws -> Bool {
    let rows = try await pool.query(
      """
      SELECT 1
      FROM appview_unread_overrides
      WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
      LIMIT 1
      """,
      logger: logger
    )
    for try await _ in rows { return true }
    return false
  }

  private func contentCounterFields(
    uri: String
  ) async throws -> (authorDid: String, publicationSite: String?, createdAt: Date)? {
    let rows = try await pool.query(
      """
      SELECT author_did, publication_site, created_at
      FROM content_items
      WHERE uri = \(uri)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode((String, String?, Date).self)
    }
    return nil
  }

  private func upsertUnreadCounter(
    _ counter: AppViewUnreadCounter,
    viewerDid: String
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_unread_counters
        (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
      VALUES
        (\(viewerDid), \(counter.publicationId), \(counter.unreadCount), \(counter.generation), \(counter.accuracy.rawValue), \(counter.dirty), \(counter.countedAt))
      ON CONFLICT (viewer_did, publication_id)
      DO UPDATE SET
        unread_count = EXCLUDED.unread_count,
        generation = EXCLUDED.generation,
        accuracy = EXCLUDED.accuracy,
        dirty = EXCLUDED.dirty,
        counted_at = EXCLUDED.counted_at
      """,
      logger: logger
    )
  }

  private func adjustUnreadCounter(
    viewerDid: String,
    publicationId: String,
    delta: Int,
    generation: Int64,
    countedAt: Date
  ) async throws {
    let current = try await fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    ).first?.unreadCount ?? 0
    let counter = AppViewUnreadCounter(
      publicationId: publicationId,
      unreadCount: max(0, current + delta),
      generation: generation,
      accuracy: .estimated,
      dirty: true,
      countedAt: countedAt
    )
    try await upsertUnreadCounter(counter, viewerDid: viewerDid)
  }

  private func markUnreadCounterDirty(
    viewerDid: String,
    publicationId: String,
    generation: Int64,
    countedAt: Date
  ) async throws {
    let current = try await fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    ).first?.unreadCount ?? 0
    let counter = AppViewUnreadCounter(
      publicationId: publicationId,
      unreadCount: current,
      generation: generation,
      accuracy: .estimated,
      dirty: true,
      countedAt: countedAt
    )
    try await upsertUnreadCounter(counter, viewerDid: viewerDid)
  }

  private static func publicationScope(from row: PostgresRow) throws -> AppViewPublicationScope? {
    let (
      viewerDid,
      publicationId,
      authorDid,
      publicationAtUri,
      publicationScopeAtUrisJSON,
      publicationSiteUrlsJSON,
      scopeKeysJSON,
      sectionKeysJSON,
      updatedAt
    ) = try row.decode((String, String, String, String?, String, String, String, String, Date).self)
    return AppViewPublicationScope(
      viewerDid: viewerDid,
      publicationId: publicationId,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: try stringArray(fromJSON: publicationScopeAtUrisJSON),
      publicationSiteUrls: try stringArray(fromJSON: publicationSiteUrlsJSON),
      scopeKeys: try stringArray(fromJSON: scopeKeysJSON),
      sectionKeys: try stringArray(fromJSON: sectionKeysJSON),
      updatedAt: updatedAt
    )
  }

  private static func unreadCounter(from row: PostgresRow) throws -> AppViewUnreadCounter? {
    let (publicationId, unreadCount, generation, accuracyRaw, dirty, countedAt) = try row.decode(
      (String, Int, Int64, String, Bool, Date).self
    )
    guard let accuracy = AppViewUnreadCounterAccuracy(rawValue: accuracyRaw) else { return nil }
    return AppViewUnreadCounter(
      publicationId: publicationId,
      unreadCount: unreadCount,
      generation: generation,
      accuracy: accuracy,
      dirty: dirty,
      countedAt: countedAt
    )
  }

  private static func jsonString(_ values: [String]) throws -> String {
    let data = try JSONEncoder().encode(values)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return string
  }

  private static func publicationScopesJSON(_ scopes: [AppViewPublicationScope]) throws -> String {
    try jsonObjectString(scopes.map { scope in
      [
        "viewer_did": scope.viewerDid,
        "publication_id": scope.publicationId,
        "author_did": scope.authorDid,
        "publication_at_uri": scope.publicationAtUri.map { $0 as Any } ?? NSNull(),
        "publication_scope_at_uris": scope.publicationScopeAtUris,
        "publication_site_urls": scope.publicationSiteUrls,
        "scope_keys": scope.scopeKeys,
        "section_keys": scope.sectionKeys,
        "updated_epoch": scope.updatedAt.timeIntervalSince1970,
      ] as [String: Any]
    })
  }

  private static func viewerFeedsJSON(_ feeds: [AppViewViewerFeed]) throws -> String {
    try jsonObjectString(feeds.map { feed in
      [
        "viewer_did": feed.viewerDid,
        "feed_kind": feed.kind.rawValue,
        "feed_id": feed.feedId,
        "updated_epoch": feed.updatedAt.timeIntervalSince1970,
      ] as [String: Any]
    })
  }

  private static func feedMembershipsJSON(_ memberships: [AppViewFeedPublication]) throws -> String {
    try jsonObjectString(memberships.map { membership in
      [
        "viewer_did": membership.viewerDid,
        "feed_kind": membership.kind.rawValue,
        "feed_id": membership.feedId,
        "publication_id": membership.publicationId,
      ]
    })
  }

  private static func jsonObjectString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return string
  }

  private static func upsertPublicationScopesQuery(_ json: String) -> PostgresQuery {
    """
    INSERT INTO appview_publication_scopes
      (viewer_did, publication_id, author_did, publication_at_uri,
       publication_scope_at_uris, publication_site_urls, scope_keys,
       section_keys, updated_at)
    SELECT
      record.viewer_did, record.publication_id, record.author_did,
      record.publication_at_uri, record.publication_scope_at_uris,
      record.publication_site_urls, record.scope_keys, record.section_keys,
      to_timestamp(record.updated_epoch)
    FROM jsonb_to_recordset(\(json)::jsonb) AS record(
      viewer_did text,
      publication_id text,
      author_did text,
      publication_at_uri text,
      publication_scope_at_uris jsonb,
      publication_site_urls jsonb,
      scope_keys jsonb,
      section_keys jsonb,
      updated_epoch double precision
    )
    ON CONFLICT (viewer_did, publication_id)
    DO UPDATE SET
      author_did = EXCLUDED.author_did,
      publication_at_uri = EXCLUDED.publication_at_uri,
      publication_scope_at_uris = EXCLUDED.publication_scope_at_uris,
      publication_site_urls = EXCLUDED.publication_site_urls,
      scope_keys = EXCLUDED.scope_keys,
      section_keys = EXCLUDED.section_keys,
      updated_at = EXCLUDED.updated_at
    """
  }

  private static func upsertViewerFeedsQuery(_ json: String) -> PostgresQuery {
    """
    INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id, updated_at)
    SELECT record.viewer_did, record.feed_kind, record.feed_id,
           to_timestamp(record.updated_epoch)
    FROM jsonb_to_recordset(\(json)::jsonb) AS record(
      viewer_did text,
      feed_kind text,
      feed_id text,
      updated_epoch double precision
    )
    ON CONFLICT (viewer_did, feed_kind, feed_id)
    DO UPDATE SET updated_at = EXCLUDED.updated_at
    """
  }

  private static func upsertFeedMembershipsQuery(_ json: String) -> PostgresQuery {
    """
    INSERT INTO appview_feed_publications
      (viewer_did, feed_kind, feed_id, publication_id)
    SELECT record.viewer_did, record.feed_kind, record.feed_id, record.publication_id
    FROM jsonb_to_recordset(\(json)::jsonb) AS record(
      viewer_did text,
      feed_kind text,
      feed_id text,
      publication_id text
    )
    ON CONFLICT (viewer_did, feed_kind, feed_id, publication_id) DO NOTHING
    """
  }

  private static func advanceAppliedInboxWatermark(
    connection: PostgresConnection,
    environment: String,
    sourceGeneration: String,
    at: Date,
    logger: Logger
  ) async throws {
    try await connection.query(
      """
      WITH barrier AS (
        SELECT MIN(seq) AS first_nonterminal_seq
        FROM appview_ingestion_inbox
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND status NOT IN ('applied', 'filtered_scope') AND reconciled_at IS NULL
      ), candidate AS (
        SELECT CASE
          WHEN barrier.first_nonterminal_seq IS NULL THEN checkpoint.last_staged_seq
          ELSE (
            SELECT MAX(inbox.seq)
            FROM appview_ingestion_inbox inbox
            WHERE inbox.environment = checkpoint.environment
              AND inbox.source_generation = checkpoint.source_generation
              AND inbox.seq < barrier.first_nonterminal_seq
              AND (inbox.status IN ('applied', 'filtered_scope')
                OR inbox.reconciled_at IS NOT NULL)
          )
        END AS seq
        FROM appview_jetstream_checkpoints checkpoint
        CROSS JOIN barrier
        WHERE checkpoint.environment = \(environment)
          AND checkpoint.source_generation = \(sourceGeneration)
      ), candidate_with_time AS (
        SELECT candidate.seq,
          COALESCE(
            (SELECT event_time FROM appview_ingestion_inbox
             WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
               AND seq = candidate.seq),
            checkpoint.last_staged_event_at
          ) AS event_at
        FROM candidate
        JOIN appview_jetstream_checkpoints checkpoint
          ON checkpoint.environment = \(environment)
         AND checkpoint.source_generation = \(sourceGeneration)
      )
      UPDATE appview_jetstream_checkpoints checkpoint
      SET last_applied_seq = candidate.seq,
          last_applied_event_at = candidate.event_at,
          last_applied_at = \(at),
          updated_at = \(at)
      FROM candidate_with_time candidate
      WHERE checkpoint.environment = \(environment)
        AND checkpoint.source_generation = \(sourceGeneration)
        AND candidate.seq IS NOT NULL
        AND (checkpoint.last_applied_seq IS NULL OR checkpoint.last_applied_seq < candidate.seq)
      """,
      logger: logger
    )
  }

  private static func stringArray(fromJSON raw: String) throws -> [String] {
    guard let data = raw.data(using: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return try JSONDecoder().decode([String].self, from: data)
  }
}
