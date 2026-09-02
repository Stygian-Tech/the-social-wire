@preconcurrency import GRDB
import Foundation
import Logging
import OperationsCore

public actor SQLiteThinAppViewStore: ThinAppViewStore {
  private let db: DatabasePool
  private let logger: Logger

public init(path dbPath: String, logger: Logger) throws {
    self.logger = logger
    var config = Configuration()
    config.label = "com.thesocialwire.thin-appview"
    self.db = try DatabasePool(path: dbPath, configuration: config)
    try db.write { db in
      try Self.migrate(db)
    }
    logger.info("SQLiteThinAppViewStore initialised", metadata: ["path": .string(dbPath)])
  }

  public func ping() async throws {
    _ = try await db.read { database in try Int.fetchOne(database, sql: "SELECT 1") }
  }

  public func claimIngestionInbox(
    environment: String,
    sourceGeneration: String,
    workerId: String,
    limit: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> [AppViewIngestionInboxItem] {
    try await db.write { db in
      let now = Self.isoString(from: at)
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT i.environment, i.source_generation, i.seq, i.source_host, i.event_kind,
                 i.repo_did, i.collection, i.operation, i.repo_rev, i.record_key,
                 i.record_cid, i.payload, i.event_time, i.attempt_count
          FROM appview_ingestion_inbox i
          WHERE i.environment = ? AND i.source_generation = ?
            AND ((i.status IN ('pending', 'retry') AND i.next_attempt_at <= ?)
              OR (i.status = 'leased' AND i.lease_expires_at <= ?))
            AND (
              (i.event_kind != 'commit' AND (
                EXISTS (
                  SELECT 1 FROM appview_publication_scopes scope
                  WHERE scope.author_did = i.repo_did OR scope.viewer_did = i.repo_did)
                OR EXISTS (
                  SELECT 1 FROM appview_viewer_feeds feed
                  WHERE feed.viewer_did = i.repo_did)))
              OR (i.collection IN (
                  'site.standard.document', 'site.standard.entry',
                  'com.standard.document', 'com.standard.entry'
                ) AND EXISTS (
                  SELECT 1 FROM appview_publication_scopes scope
                  WHERE scope.author_did = i.repo_did))
              OR (i.collection IN (
                  'app.skyreader.feed.subscription', 'site.standard.graph.subscription'
                ) AND (
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
          LIMIT ?
          """,
        arguments: [environment, sourceGeneration, now, now, max(1, limit)]
      )
      var claimed: [AppViewIngestionInboxItem] = []
      claimed.reserveCapacity(rows.count)
      for row in rows {
        let sequence: Int64 = row["seq"]
        let leaseToken = UUID().uuidString.lowercased()
        try db.execute(
          sql: """
            UPDATE appview_ingestion_inbox
            SET status = 'leased', lease_owner = ?, lease_token = ?, lease_expires_at = ?,
                updated_at = ?
            WHERE environment = ? AND source_generation = ? AND seq = ?
              AND ((status IN ('pending', 'retry') AND next_attempt_at <= ?)
                OR (status = 'leased' AND lease_expires_at <= ?))
            """,
          arguments: [
            workerId,
            leaseToken,
            Self.isoString(from: leaseUntil),
            now,
            environment,
            sourceGeneration,
            sequence,
            now,
            now,
          ]
        )
        guard db.changesCount == 1 else { continue }
        let eventKindRaw: String = row["event_kind"]
        let payloadRaw: String = row["payload"]
        let eventTimeRaw: String = row["event_time"]
        guard
          let eventKind = AppViewIngestionEventKind(rawValue: eventKindRaw),
          let payload = payloadRaw.data(using: .utf8),
          let eventTime = Self.date(fromIso: eventTimeRaw)
        else { throw AppViewIngestionInboxStoreError.invalidRow }
        claimed.append(
          AppViewIngestionInboxItem(
            environment: row["environment"],
            sourceGeneration: row["source_generation"],
            sequence: sequence,
            sourceHost: row["source_host"],
            eventKind: eventKind,
            repoDid: row["repo_did"],
            collection: row["collection"],
            operation: row["operation"],
            repoRev: row["repo_rev"],
            recordKey: row["record_key"],
            recordCID: row["record_cid"],
            payload: payload,
            eventTime: eventTime,
            attemptCount: row["attempt_count"],
            leaseToken: leaseToken,
            leaseExpiresAt: leaseUntil
          )
        )
      }
      return claimed
    }
  }

  public func filterIngestionInboxOutsideScope(
    environment: String,
    sourceGeneration: String,
    policy: String,
    limit: Int,
    expiresAt: Date,
    at: Date
  ) async throws -> Int {
    try await db.write { db in
      let now = Self.isoString(from: at)
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT inbox.seq
          FROM appview_ingestion_inbox inbox
          WHERE inbox.environment = ? AND inbox.source_generation = ?
            AND ((inbox.status IN ('pending', 'retry') AND inbox.next_attempt_at <= ?)
              OR (inbox.status = 'leased' AND inbox.lease_expires_at <= ?))
            AND (
              (inbox.event_kind = 'commit' AND (
                inbox.collection IS NULL OR inbox.collection NOT IN (
                  'site.standard.document', 'site.standard.entry',
                  'com.standard.document', 'com.standard.entry',
                  'app.skyreader.feed.subscription', 'site.standard.graph.subscription'
                )
                OR (inbox.collection IN (
                    'site.standard.document', 'site.standard.entry',
                    'com.standard.document', 'com.standard.entry'
                  ) AND NOT EXISTS (
                    SELECT 1 FROM appview_publication_scopes scope
                    WHERE scope.author_did = inbox.repo_did))
                OR (inbox.collection IN (
                    'app.skyreader.feed.subscription', 'site.standard.graph.subscription'
                  ) AND NOT EXISTS (
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
          LIMIT ?
          """,
        arguments: [
          environment,
          sourceGeneration,
          now,
          now,
          max(1, min(limit, 10_000)),
        ]
      )
      var filtered = 0
      for row in rows {
        let sequence: Int64 = row["seq"]
        try db.execute(
          sql: """
            UPDATE appview_ingestion_inbox
            SET status = 'filtered_scope', filtered_scope_policy = ?, filtered_scope_at = ?,
                applied_at = NULL, reconciled_at = NULL,
                lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
                failure_category = NULL, failure_reason = NULL,
                expires_at = ?, updated_at = ?
            WHERE environment = ? AND source_generation = ? AND seq = ?
              AND ((status IN ('pending', 'retry') AND next_attempt_at <= ?)
                OR (status = 'leased' AND lease_expires_at <= ?))
            """,
          arguments: [
            String(policy.prefix(128)),
            now,
            Self.isoString(from: expiresAt),
            now,
            environment,
            sourceGeneration,
            sequence,
            now,
            now,
          ]
        )
        filtered += db.changesCount
      }
      return filtered
    }
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
    try await db.write { db in
      let now = Self.isoString(from: at)
      try db.execute(
        sql: """
          UPDATE appview_ingestion_inbox
          SET status = 'applied', applied_at = ?, lease_owner = NULL, lease_token = NULL,
              lease_expires_at = NULL, failure_category = NULL, failure_reason = NULL,
              expires_at = ?, updated_at = ?
          WHERE environment = ? AND source_generation = ? AND seq = ?
            AND status = 'leased' AND lease_owner = ? AND lease_token = ?
          """,
        arguments: [
          now,
          Self.isoString(from: expiresAt),
          now,
          environment,
          sourceGeneration,
          sequence,
          workerId,
          leaseToken,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.staleLease }
    }
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
    try await updateFailedInboxLease(
      environment: environment,
      sourceGeneration: sourceGeneration,
      sequence: sequence,
      workerId: workerId,
      leaseToken: leaseToken,
      status: "retry",
      failureCategory: failureCategory,
      failureReason: failureReason,
      nextAttemptAt: nextAttemptAt,
      expiresAt: nil,
      at: at
    )
  }

  public func advanceIngestionInboxAppliedWatermark(
    environment: String,
    sourceGeneration: String,
    at: Date
  ) async throws {
    try await db.write { db in
      try Self.advanceAppliedInboxWatermark(
        db: db,
        environment: environment,
        sourceGeneration: sourceGeneration,
        at: at
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
    try await db.write { db in
      try db.execute(
        sql: """
          UPDATE appview_ingestion_inbox
          SET lease_expires_at = ?, updated_at = ?
          WHERE environment = ? AND source_generation = ? AND seq = ?
            AND status = 'leased' AND lease_owner = ? AND lease_token = ?
          """,
        arguments: [
          Self.isoString(from: leaseUntil),
          Self.isoString(from: at),
          environment,
          sourceGeneration,
          sequence,
          workerId,
          leaseToken,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.staleLease }
    }
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
    try await db.write { db in
      try Self.updateFailedInboxLease(
        db: db,
        environment: environment,
        sourceGeneration: sourceGeneration,
        sequence: sequence,
        workerId: workerId,
        leaseToken: leaseToken,
        status: "dead_letter",
        failureCategory: failureCategory,
        failureReason: failureReason,
        nextAttemptAt: at,
        expiresAt: expiresAt,
        at: at
      )
      let requestId = "\(sourceGeneration):\(sequence):\(repoDid)"
      let now = Self.isoString(from: at)
      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_reconciliation_requests
            (environment, id, source_generation, repo_did, reason, trigger_seq, status,
             attempt_count, next_attempt_at, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?)
          ON CONFLICT (environment, source_generation, repo_did, trigger_seq, reason) DO NOTHING
          """,
        arguments: [
          environment,
          requestId,
          sourceGeneration,
          repoDid,
          failureCategory,
          sequence,
          now,
          now,
          now,
        ]
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
    try await db.write { db in
      let now = Self.isoString(from: at)
      try db.execute(
        sql: """
          UPDATE appview_ingestion_inbox
          SET reconciled_at = ?, expires_at = ?, updated_at = ?
          WHERE environment = ? AND source_generation = ? AND seq = ? AND repo_did = ?
            AND status = 'leased' AND lease_owner = ? AND lease_token = ?
          """,
        arguments: [
          now,
          Self.isoString(from: expiresAt),
          now,
          environment,
          sourceGeneration,
          sequence,
          repoDid,
          workerId,
          leaseToken,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.staleLease }
      try db.execute(
        sql: """
          UPDATE appview_jetstream_checkpoints
          SET last_reconciled_repo_rev = ?, last_reconciled_at = ?, updated_at = ?
          WHERE environment = ? AND source_generation = ?
        """,
        arguments: [repoRev, now, now, environment, sourceGeneration]
      )
      try db.execute(
        sql: """
          UPDATE appview_ingestion_reconciliation_requests
          SET status = 'completed', completed_at = ?, updated_at = ?,
              lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL
          WHERE environment = ? AND source_generation = ? AND repo_did = ?
            AND trigger_seq = ? AND status != 'completed'
          """,
        arguments: [now, now, environment, sourceGeneration, repoDid, sequence]
      )
      try Self.advanceAppliedInboxWatermark(
        db: db,
        environment: environment,
        sourceGeneration: sourceGeneration,
        at: at
      )
    }
  }

  public func deleteExpiredIngestionInbox(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM appview_ingestion_inbox
          WHERE rowid IN (
            SELECT rowid
            FROM appview_ingestion_inbox
            WHERE environment = ? AND expires_at <= ?
              AND (status IN ('applied', 'filtered_scope')
                OR (status = 'dead_letter' AND reconciled_at IS NOT NULL))
            ORDER BY expires_at ASC, seq ASC
            LIMIT ?
          )
          """,
        arguments: [environment, Self.isoString(from: before), max(1, batchSize)]
      )
      return db.changesCount
    }
  }

  public func resolveRecoveredIngestionIncidents(
    environment: String,
    sourceGeneration: String,
    at: Date
  ) async throws -> Int {
    try await db.write { db in
      guard let checkpoint = try Row.fetchOne(
        db,
        sql: """
          SELECT replay_state, replay_sealed_seq, last_applied_seq
          FROM appview_jetstream_checkpoints
          WHERE environment = ? AND source_generation = ?
          """,
        arguments: [environment, sourceGeneration]
      ) else { return 0 }
      let replayState: String = checkpoint["replay_state"]
      let sealedSequence: Int64? = checkpoint["replay_sealed_seq"]
      let terminalPrefix: Int64? = checkpoint["last_applied_seq"]
      guard replayState == "live", let sealedSequence, let terminalPrefix,
        terminalPrefix >= sealedSequence
      else { return 0 }
      let blocked = try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM appview_ingestion_inbox
            WHERE environment = ? AND source_generation = ? AND seq <= ?
              AND status NOT IN ('applied', 'filtered_scope')
              AND reconciled_at IS NULL)
          """,
        arguments: [environment, sourceGeneration, sealedSequence]
      ) ?? true
      guard !blocked else { return 0 }
      let evidenceData = try JSONSerialization.data(withJSONObject: [
        "recovery": "terminal_prefix_reached",
        "sealedSequence": String(sealedSequence),
        "terminalPrefixSequence": String(terminalPrefix),
        "allStagedRowsThroughSealedTerminal": true,
      ], options: [.sortedKeys])
      guard let evidence = String(data: evidenceData, encoding: .utf8) else {
        throw AppViewIngestionInboxStoreError.invalidRow
      }
      let now = Self.isoString(from: at)
      try db.execute(
        sql: """
          UPDATE appview_ingestion_incidents
          SET status = 'resolved', replay_state = 'live', replay_sealed_seq = ?,
              recovered_through_cursor = ?,
              verification_evidence = json_patch(verification_evidence, ?), resolved_at = ?,
              updated_at = ?, version = version + 1
          WHERE environment = ? AND source_generation = ? AND source = 'jetstream-v2'
            AND cursor_kind = 'jetstream_v2_seq'
            AND category IN ('transport_error', 'consumer_too_slow', 'cursor_too_old',
              'replay_budget', 'no_progress_24h')
            AND status IN ('open', 'recovering')
          """,
        arguments: [
          sealedSequence, terminalPrefix, evidence, now, now, environment, sourceGeneration,
        ]
      )
      return db.changesCount
    }
  }

  public func resolveTerminalRetiredGenerationIncidents(
    environment: String,
    activeSourceGeneration: String,
    activeLeaseName: String,
    at: Date
  ) async throws -> Int {
    try await db.write { db in
      let now = Self.isoString(from: at)
      guard let successor = try Row.fetchOne(
        db,
        sql: """
          SELECT checkpoint.source_generation, checkpoint.source_host,
                 checkpoint.stream_nsid, checkpoint.cursor_kind,
                 checkpoint.replay_after_seq, checkpoint.last_staged_seq,
                 checkpoint.updated_at AS checkpoint_observed_at,
                 lease.updated_at AS lease_observed_at
          FROM appview_jetstream_checkpoints checkpoint
          JOIN appview_ingestion_leases lease
            ON lease.environment = checkpoint.environment
           AND lease.source_generation = checkpoint.source_generation
           AND lease.lease_name = ?
           AND lease.released_at IS NULL
           AND lease.lease_expires_at >= ?
          WHERE checkpoint.environment = ? AND checkpoint.source_generation = ?
            AND checkpoint.replay_state = 'live'
          ORDER BY lease.updated_at DESC
          LIMIT 1
          """,
        arguments: [activeLeaseName, now, environment, activeSourceGeneration]
      ) else { return 0 }
      let successorGeneration: String = successor["source_generation"]
      let successorSourceHost: String = successor["source_host"]
      let successorStreamNSID: String = successor["stream_nsid"]
      let successorCursorKind: String = successor["cursor_kind"]
      let replayAfterSequence: Int64? = successor["replay_after_seq"]
      let lastStagedSequence: Int64? = successor["last_staged_seq"]
      guard let successorReplayAfterSequence = replayAfterSequence,
            let successorLastStagedSequence = lastStagedSequence else { return 0 }
      let successorCheckpointObservedAt: String = successor["checkpoint_observed_at"]
      let successorLeaseObservedAt: String = successor["lease_observed_at"]
      let retired = try Row.fetchAll(
        db,
        sql: """
          SELECT checkpoint.source_generation, checkpoint.last_staged_seq,
                 checkpoint.last_applied_seq
          FROM appview_jetstream_checkpoints checkpoint
          WHERE checkpoint.environment = ? AND checkpoint.source_generation != ?
            AND checkpoint.source_host = ? AND checkpoint.stream_nsid = ?
            AND checkpoint.cursor_kind = ?
            AND ? < checkpoint.last_staged_seq
            AND ? >= checkpoint.last_staged_seq
            AND checkpoint.replay_state = 'live'
            AND checkpoint.last_staged_seq IS NOT NULL
            AND checkpoint.last_applied_seq IS NOT NULL
            AND checkpoint.last_applied_seq >= checkpoint.last_staged_seq
            AND NOT EXISTS (
              SELECT 1 FROM appview_ingestion_leases retired_lease
              WHERE retired_lease.environment = checkpoint.environment
                AND retired_lease.source_generation = checkpoint.source_generation
                AND retired_lease.released_at IS NULL
                AND retired_lease.lease_expires_at >= ?)
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
          ORDER BY checkpoint.source_generation
          """,
        arguments: [
          environment, successorGeneration, successorSourceHost, successorStreamNSID,
          successorCursorKind, successorReplayAfterSequence, successorLastStagedSequence, now,
        ]
      )
      var resolved = 0
      for checkpoint in retired {
        let retiredGeneration: String = checkpoint["source_generation"]
        let lastStagedSequence: Int64 = checkpoint["last_staged_seq"]
        let terminalPrefixSequence: Int64 = checkpoint["last_applied_seq"]
        let evidenceData = try JSONSerialization.data(withJSONObject: [
          "recovery": "retired_generation_terminal",
          "resolutionPolicy": "retired-generation-terminal-v1",
          "retiredSourceGeneration": retiredGeneration,
          "successorSourceGeneration": successorGeneration,
          "successorLeaseName": activeLeaseName,
          "successorReplayAfterSequence": String(successorReplayAfterSequence),
          "successorLastStagedSequence": String(successorLastStagedSequence),
          "identityAndInclusiveOverlapVerified": true,
          "retiredLastStagedSequence": String(lastStagedSequence),
          "retiredTerminalPrefixSequence": String(terminalPrefixSequence),
          "allRetiredRowsTerminal": true,
          "successorCheckpointObservedAt": successorCheckpointObservedAt,
          "successorLeaseObservedAt": successorLeaseObservedAt,
        ], options: [.sortedKeys])
        guard let evidence = String(data: evidenceData, encoding: .utf8) else {
          throw AppViewIngestionInboxStoreError.invalidRow
        }
        try db.execute(
          sql: """
            UPDATE appview_ingestion_incidents
            SET status = 'resolved', replay_state = 'live', recovered_through_cursor = ?,
                verification_evidence = json_patch(verification_evidence, ?), resolved_at = ?,
                updated_at = ?, version = version + 1
            WHERE environment = ? AND source_generation = ? AND source = 'jetstream-v2'
              AND cursor_kind = 'jetstream_v2_seq' AND category = 'fatal_stream'
              AND status IN ('open', 'recovering')
              AND (start_cursor IS NULL OR start_cursor <= ?)
              AND (end_cursor IS NULL OR end_cursor <= ?)
            """,
          arguments: [
            terminalPrefixSequence, evidence, now, now, environment, retiredGeneration,
            terminalPrefixSequence, terminalPrefixSequence,
          ]
        )
        resolved += db.changesCount
      }
      return resolved
    }
  }

  public func claimIngestionReconciliationRequests(
    environment: String,
    sourceGeneration: String,
    workerId: String,
    limit: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> [AppViewIngestionReconciliationRequest] {
    try await db.write { db in
      let now = Self.isoString(from: at)
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT request.* FROM appview_ingestion_reconciliation_requests request
          WHERE request.environment = ? AND request.source_generation = ?
            AND ((request.status = 'pending' AND request.next_attempt_at <= ?)
              OR (request.status = 'leased' AND request.lease_expires_at <= ?))
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
                AND inbox.lease_expires_at > ?)
          ORDER BY request.trigger_seq, request.id LIMIT ?
          """,
        arguments: [environment, sourceGeneration, now, now, now, max(1, limit)]
      )
      var requests: [AppViewIngestionReconciliationRequest] = []
      for row in rows {
        let id: String = row["id"]
        let token = UUID().uuidString.lowercased()
        try db.execute(
          sql: """
            UPDATE appview_ingestion_reconciliation_requests
            SET status = 'leased', lease_owner = ?, lease_token = ?, lease_expires_at = ?,
                updated_at = ?
            WHERE environment = ? AND id = ?
              AND ((status = 'pending' AND next_attempt_at <= ?)
                OR (status = 'leased' AND lease_expires_at <= ?))
            """,
          arguments: [
            workerId, token, Self.isoString(from: leaseUntil), now,
            environment, id, now, now,
          ]
        )
        guard db.changesCount == 1 else { continue }
        requests.append(AppViewIngestionReconciliationRequest(
          environment: environment, id: id, sourceGeneration: sourceGeneration,
          repoDid: row["repo_did"], reason: row["reason"],
          triggerSequence: row["trigger_seq"], attemptCount: row["attempt_count"],
          leaseToken: token, leaseExpiresAt: leaseUntil))
      }
      return requests
    }
  }

  public func renewIngestionReconciliationLease(
    environment: String,
    requestId: String,
    workerId: String,
    leaseToken: String,
    leaseUntil: Date,
    at: Date
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          UPDATE appview_ingestion_reconciliation_requests
          SET lease_expires_at = ?, updated_at = ?
          WHERE environment = ? AND id = ? AND status = 'leased'
            AND lease_owner = ? AND lease_token = ?
          """,
        arguments: [
          Self.isoString(from: leaseUntil), Self.isoString(from: at), environment,
          requestId, workerId, leaseToken,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.staleLease }
    }
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
    try await db.write { db in
      try db.execute(
        sql: """
          UPDATE appview_ingestion_reconciliation_requests
          SET status = CASE WHEN attempt_count + 1 >= 10 THEN 'failed' ELSE 'pending' END,
              attempt_count = attempt_count + 1, next_attempt_at = ?,
              lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
              reason = CASE WHEN attempt_count + 1 >= 10
                THEN reason || ':reconciliation_failed:' || ? ELSE reason END,
              updated_at = ?
          WHERE environment = ? AND id = ? AND status = 'leased'
            AND lease_owner = ? AND lease_token = ?
          """,
        arguments: [
          Self.isoString(from: nextAttemptAt), String(failureReason.prefix(512)),
          Self.isoString(from: at), environment, requestId, workerId, leaseToken,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.staleLease }
    }
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
    try await db.write { db in
      let now = Self.isoString(from: at)
      try db.execute(
        sql: """
          UPDATE appview_ingestion_reconciliation_requests
          SET status = 'completed', completed_at = ?, updated_at = ?,
              lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL
          WHERE environment = ? AND id = ? AND status = 'leased'
            AND lease_owner = ? AND lease_token = ?
          """,
        arguments: [now, now, environment, requestId, workerId, leaseToken]
      )
      guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.staleLease }
      try db.execute(
        sql: """
          UPDATE appview_ingestion_inbox
          SET reconciled_at = ?, expires_at = ?, updated_at = ?
          WHERE environment = ? AND source_generation = ? AND seq = ? AND repo_did = ?
            AND status = 'dead_letter'
          """,
        arguments: [
          now, Self.isoString(from: expiresAt), now, environment, sourceGeneration,
          triggerSequence, repoDid,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.invalidRow }
      try db.execute(
        sql: """
          UPDATE appview_jetstream_checkpoints
          SET last_reconciled_repo_rev = COALESCE(
                (SELECT repo_rev FROM appview_ingestion_inbox
                 WHERE environment = ? AND source_generation = ? AND seq = ?),
                last_reconciled_repo_rev),
              last_reconciled_at = ?, updated_at = ?
          WHERE environment = ? AND source_generation = ?
          """,
        arguments: [
          environment, sourceGeneration, triggerSequence, now, now,
          environment, sourceGeneration,
        ]
      )
      try Self.advanceAppliedInboxWatermark(
        db: db, environment: environment, sourceGeneration: sourceGeneration, at: at)
    }
  }

  private static func migrate(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS content_items (
        uri TEXT PRIMARY KEY,
        cid TEXT NOT NULL,
        author_did TEXT NOT NULL,
        collection TEXT NOT NULL,
        created_at TEXT NOT NULL,
        indexed_at TEXT NOT NULL,
        publication_site TEXT,
        render_json TEXT NOT NULL,
        expires_at TEXT NOT NULL
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_collection_created
        ON content_items (author_did, collection, created_at DESC);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_expires
        ON content_items (expires_at);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_expires
        ON content_items (author_did, expires_at);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_site_expires
        ON content_items (author_did, publication_site, expires_at);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_created_uri
        ON content_items (author_did, created_at DESC, uri DESC);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_site_created_uri
        ON content_items (author_did, publication_site, created_at DESC, uri DESC);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS read_marks (
        viewer_did TEXT NOT NULL,
        subject_uri TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, subject_uri)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_read_marks_viewer_created
        ON read_marks (viewer_did, created_at DESC);
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_read_marks_cleanup
        ON read_marks (created_at, viewer_did, subject_uri);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_ingestion_checkpoints (
        environment TEXT NOT NULL,
        source TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        collection TEXT NOT NULL,
        cursor TEXT,
        event_time TEXT,
        observed_at TEXT NOT NULL,
        PRIMARY KEY (environment, source, repo_did, collection)
      );
      """)

    try migrateIngestionCheckpointEnvironmentIfNeeded(db)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_ingestion_checkpoints_observed
        ON appview_ingestion_checkpoints (observed_at);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_jetstream_checkpoints (
        environment TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        source_host TEXT NOT NULL,
        stream_nsid TEXT NOT NULL,
        filter_fingerprint TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        last_staged_seq INTEGER,
        last_staged_event_at TEXT,
        last_staged_at TEXT,
        last_applied_seq INTEGER,
        last_applied_event_at TEXT,
        last_applied_at TEXT,
        last_reconciled_repo_rev TEXT,
        last_reconciled_at TEXT,
        replay_state TEXT NOT NULL DEFAULT 'idle',
        replay_after_seq INTEGER,
        replay_sealed_seq INTEGER,
        replay_bytes_downloaded INTEGER NOT NULL DEFAULT 0,
        replay_retry_count INTEGER NOT NULL DEFAULT 0,
        replay_range_resume_count INTEGER NOT NULL DEFAULT 0,
        replay_last_progress_at TEXT,
        replay_etag TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (environment, source_generation)
      );
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_ingestion_inbox (
        environment TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        seq INTEGER NOT NULL,
        source_host TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        event_kind TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        collection TEXT,
        operation TEXT,
        repo_rev TEXT,
        record_key TEXT,
        record_cid TEXT,
        payload TEXT NOT NULL,
        event_time TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        lease_owner TEXT,
        lease_token TEXT,
        lease_expires_at TEXT,
        failure_category TEXT,
        failure_reason TEXT,
        staged_at TEXT NOT NULL,
        applied_at TEXT,
        dead_lettered_at TEXT,
        reconciled_at TEXT,
        filtered_scope_policy TEXT,
        filtered_scope_at TEXT,
        expires_at TEXT,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (environment, source_generation, seq)
      );
      """)
    try migrateIngestionInboxScopeFilterColumnsIfNeeded(db)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_ingestion_inbox_claim
        ON appview_ingestion_inbox
          (environment, source_generation, status, next_attempt_at, lease_expires_at, seq);
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_ingestion_inbox_repo_fifo
        ON appview_ingestion_inbox (environment, source_generation, repo_did, seq, status);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_ingestion_incidents (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        source_generation TEXT,
        source_host TEXT,
        source TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        start_cursor INTEGER,
        end_cursor INTEGER,
        category TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'open',
        occurrence_count INTEGER NOT NULL DEFAULT 1,
        first_detected_at TEXT NOT NULL,
        last_detected_at TEXT NOT NULL,
        last_error TEXT,
        replay_state TEXT,
        replay_bytes_downloaded INTEGER NOT NULL DEFAULT 0,
        replay_retry_count INTEGER NOT NULL DEFAULT 0,
        replay_range_resume_count INTEGER NOT NULL DEFAULT 0,
        replay_sealed_seq INTEGER,
        recovered_through_cursor INTEGER,
        verification_evidence TEXT NOT NULL DEFAULT '{}',
        resolved_at TEXT,
        updated_at TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (environment, id)
      );
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_ingestion_reconciliation_requests (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        reason TEXT NOT NULL,
        trigger_seq INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        lease_owner TEXT,
        lease_token TEXT,
        lease_expires_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        PRIMARY KEY (environment, id),
        UNIQUE (environment, source_generation, repo_did, trigger_seq, reason)
      );
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_ingestion_leases (
        environment TEXT NOT NULL,
        lease_name TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        fencing_token INTEGER NOT NULL,
        acquired_at TEXT NOT NULL,
        lease_expires_at TEXT NOT NULL,
        released_at TEXT,
        updated_at TEXT NOT NULL,
        CHECK (fencing_token > 0),
        PRIMARY KEY (environment, lease_name)
      );
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_repo_state (
        environment TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        repo_rev TEXT,
        account_status TEXT NOT NULL,
        pds_base TEXT,
        last_event_id INTEGER,
        last_event_live INTEGER,
        parity_status TEXT NOT NULL,
        matched_event_count INTEGER NOT NULL DEFAULT 0,
        mismatched_event_count INTEGER NOT NULL DEFAULT 0,
        last_mismatch TEXT,
        last_indexed_at TEXT,
        last_validated_at TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (environment, repo_did)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_repo_state_parity
        ON appview_tap_repo_state (environment, parity_status, updated_at DESC);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_parity_discrepancies (
        environment TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        repo_did TEXT NOT NULL,
        uri TEXT NOT NULL,
        collection TEXT NOT NULL,
        mismatch_kind TEXT NOT NULL,
        expected_cid TEXT,
        observed_cid TEXT,
        status TEXT NOT NULL,
        opened_at TEXT NOT NULL,
        resolved_at TEXT,
        resolution_event_id INTEGER,
        PRIMARY KEY (environment, event_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_parity_discrepancies_open
        ON appview_tap_parity_discrepancies (environment, repo_did, uri, opened_at)
        WHERE status = 'open';
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_event_receipts (
        environment TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        repo_did TEXT NOT NULL,
        event_type TEXT NOT NULL,
        processed_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (environment, event_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_event_receipts_environment_expires
        ON appview_tap_event_receipts (environment, expires_at, event_id);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_repository_registrations (
        environment TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        is_registered INTEGER NOT NULL,
        registered_at TEXT,
        removed_at TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (environment, repo_did)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_repository_registrations_active
        ON appview_tap_repository_registrations (environment, repo_did)
        WHERE is_registered = 1;
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_projection_repair_outbox (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        uri TEXT NOT NULL,
        author_did TEXT NOT NULL,
        publication_site TEXT,
        action TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        lease_owner TEXT,
        lease_until TEXT,
        next_attempt_at TEXT NOT NULL,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (environment, id),
        UNIQUE (environment, event_id)
      );
      """)

    try migrateProjectionRepairEnvironmentPrimaryKeyIfNeeded(db)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_projection_repair_claim
        ON appview_projection_repair_outbox
          (environment, status, next_attempt_at, lease_until, created_at);
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_projection_repair_cleanup
        ON appview_projection_repair_outbox (environment, status, expires_at, id);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS rss_feed_fetch_metadata (
        feed_url TEXT PRIMARY KEY,
        etag TEXT,
        last_modified TEXT,
        last_poll_at TEXT,
        backoff_until TEXT,
        consecutive_error_count INTEGER NOT NULL DEFAULT 0
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_rss_feed_fetch_metadata_backoff
        ON rss_feed_fetch_metadata (backoff_until);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_publication_scopes (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        author_did TEXT NOT NULL,
        publication_at_uri TEXT,
        publication_scope_at_uris TEXT NOT NULL,
        publication_site_urls TEXT NOT NULL,
        scope_keys TEXT NOT NULL,
        section_keys TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_author
        ON appview_publication_scopes (author_did);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_viewer_feeds (
        viewer_did TEXT NOT NULL,
        feed_kind TEXT NOT NULL,
        feed_id TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, feed_kind, feed_id)
      );
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_feed_publications (
        viewer_did TEXT NOT NULL,
        feed_kind TEXT NOT NULL,
        feed_id TEXT NOT NULL DEFAULT '',
        publication_id TEXT NOT NULL,
        PRIMARY KEY (viewer_did, feed_kind, feed_id, publication_id),
        FOREIGN KEY (viewer_did, feed_kind, feed_id)
          REFERENCES appview_viewer_feeds (viewer_did, feed_kind, feed_id)
          ON DELETE CASCADE
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_feed_publications_scope
        ON appview_feed_publications (viewer_did, feed_kind, feed_id, publication_id);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_viewer
        ON appview_publication_scopes (viewer_did);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_unread_counters (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        unread_count INTEGER NOT NULL,
        generation INTEGER NOT NULL,
        accuracy TEXT NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 0,
        counted_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_unread_counters_dirty
        ON appview_unread_counters (dirty, counted_at);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_publication_read_floors (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        read_floor_at TEXT NOT NULL,
        read_floor_uri TEXT,
        generation INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)

    let floorColumns = try Row.fetchAll(
      db,
      sql: "PRAGMA table_info(appview_publication_read_floors)"
    ).map { row -> String in row["name"] }
    if !floorColumns.contains("read_floor_uri") {
      try db.execute(
        sql: "ALTER TABLE appview_publication_read_floors ADD COLUMN read_floor_uri TEXT"
      )
    }

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_unread_overrides (
        viewer_did TEXT NOT NULL,
        subject_uri TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, subject_uri)
      );
      CREATE INDEX IF NOT EXISTS idx_appview_unread_overrides_cleanup
        ON appview_unread_overrides (created_at, viewer_did, subject_uri);
      """)
  }

  private static func migrateIngestionInboxScopeFilterColumnsIfNeeded(
    _ db: Database
  ) throws {
    let columns = try Row.fetchAll(
      db,
      sql: "PRAGMA table_info(appview_ingestion_inbox)"
    ).map { row -> String in row["name"] }
    if !columns.contains("filtered_scope_policy") {
      try db.execute(
        sql: "ALTER TABLE appview_ingestion_inbox ADD COLUMN filtered_scope_policy TEXT"
      )
    }
    if !columns.contains("filtered_scope_at") {
      try db.execute(
        sql: "ALTER TABLE appview_ingestion_inbox ADD COLUMN filtered_scope_at TEXT"
      )
    }
  }

  /// SQLite cannot add a column to an existing primary key. Rebuild the legacy table while
  /// quarantining its unscoped evidence instead of silently assigning it to the active environment.
  private static func migrateIngestionCheckpointEnvironmentIfNeeded(_ db: Database) throws {
    let columns = try Row.fetchAll(
      db,
      sql: "PRAGMA table_info(appview_ingestion_checkpoints)"
    ).map { row -> String in row["name"] }
    guard !columns.contains("environment") else { return }

    try db.execute(sql: """
      ALTER TABLE appview_ingestion_checkpoints
        RENAME TO appview_ingestion_checkpoints_legacy_unscoped;
      """)
    try db.execute(sql: """
      CREATE TABLE appview_ingestion_checkpoints (
        environment TEXT NOT NULL,
        source TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        collection TEXT NOT NULL,
        cursor TEXT,
        event_time TEXT,
        observed_at TEXT NOT NULL,
        PRIMARY KEY (environment, source, repo_did, collection)
      );
      """)
    try db.execute(sql: """
      INSERT INTO appview_ingestion_checkpoints
        (environment, source, repo_did, collection, cursor, event_time, observed_at)
      SELECT '__legacy_unscoped__', source, repo_did, collection, cursor, event_time, observed_at
      FROM appview_ingestion_checkpoints_legacy_unscoped;
      """)
    try db.execute(sql: "DROP TABLE appview_ingestion_checkpoints_legacy_unscoped;")
  }

  /// Early development builds used a global outbox id primary key. Rebuild it as an
  /// environment-scoped identifier so SQLite has the same isolation contract as Postgres.
  private static func migrateProjectionRepairEnvironmentPrimaryKeyIfNeeded(
    _ db: Database
  ) throws {
    let primaryKeyColumns = try Row.fetchAll(
      db,
      sql: "PRAGMA table_info(appview_projection_repair_outbox)"
    ).compactMap { row -> (position: Int, name: String)? in
      let position: Int = row["pk"]
      guard position > 0 else { return nil }
      return (position, row["name"])
    }.sorted { $0.position < $1.position }.map(\.name)
    guard primaryKeyColumns != ["environment", "id"] else { return }

    try db.execute(sql: """
      ALTER TABLE appview_projection_repair_outbox
        RENAME TO appview_projection_repair_outbox_legacy;
      CREATE TABLE appview_projection_repair_outbox (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        uri TEXT NOT NULL,
        author_did TEXT NOT NULL,
        publication_site TEXT,
        action TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        lease_owner TEXT,
        lease_until TEXT,
        next_attempt_at TEXT NOT NULL,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (environment, id),
        UNIQUE (environment, event_id)
      );
      INSERT INTO appview_projection_repair_outbox (
        environment, id, event_id, uri, author_did, publication_site, action, status,
        attempts, lease_owner, lease_until, next_attempt_at, last_error, created_at,
        updated_at, expires_at
      )
      SELECT environment, id, event_id, uri, author_did, publication_site, action, status,
        attempts, lease_owner, lease_until, next_attempt_at, last_error, created_at,
        updated_at, expires_at
      FROM appview_projection_repair_outbox_legacy;
      DROP TABLE appview_projection_repair_outbox_legacy;
      """)
  }

  public func upsertContentItem(_ item: IndexedContentItem) async throws {
    let renderJSON = try item.render.encodedJSON()
    let createdAt = Self.isoString(from: item.createdAt)
    let indexedAt = Self.isoString(from: item.indexedAt)
    let expiresAt = Self.isoString(from: item.expiresAt)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO content_items
            (uri, cid, author_did, collection, created_at, indexed_at, publication_site, render_json, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (uri) DO UPDATE SET
            cid = excluded.cid,
            author_did = excluded.author_did,
            collection = excluded.collection,
            created_at = excluded.created_at,
            indexed_at = excluded.indexed_at,
            publication_site = excluded.publication_site,
            render_json = excluded.render_json,
            expires_at = excluded.expires_at
          """,
        arguments: [
          item.uri,
          item.cid,
          item.authorDid,
          item.collection,
          createdAt,
          indexedAt,
          item.publicationSite,
          renderJSON,
          expiresAt,
        ]
      )
    }
  }

  public func deleteContentItem(uri: String) async throws {
    try await db.write { db in
      try db.execute(sql: "DELETE FROM content_items WHERE uri = ?", arguments: [uri])
    }
  }

  public func deleteContentItems(authorDid: String) async throws -> Int {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM content_items WHERE author_did = ?",
        arguments: [authorDid]
      )
      return db.changesCount
    }
  }

  public func deleteContentItems(
    authorDid: String,
    excludingURIs: [String],
    indexedAtOrBefore: Date
  ) async throws -> Int {
    return try await db.write { db in
      let cutoff = Self.isoString(from: indexedAtOrBefore)
      let existingURIs = try String.fetchAll(
        db,
        sql: "SELECT uri FROM content_items WHERE author_did = ? AND indexed_at <= ?",
        arguments: [authorDid, cutoff]
      )
      let retainedURIs = Set(excludingURIs)
      let staleURIs = existingURIs.filter { !retainedURIs.contains($0) }
      var deleted = 0
      for start in stride(from: 0, to: staleURIs.count, by: 500) {
        let end = min(start + 500, staleURIs.count)
        let batch = Array(staleURIs[start..<end])
        let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
        try db.execute(
          sql: """
            DELETE FROM content_items
            WHERE author_did = ?
              AND uri IN (\(placeholders))
            """,
          arguments: StatementArguments([authorDid] + batch)
        )
        deleted += db.changesCount
      }
      return deleted
    }
  }

  public func fetchContentIdentity(uri: String) async throws -> IndexedContentIdentity? {
    let nowIso = Self.isoString(from: Date())
    return try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT uri, cid, author_did, collection
          FROM content_items
          WHERE uri = ?
            AND expires_at > ?
          LIMIT 1
          """,
        arguments: [uri, nowIso]
      ) else { return nil }
      return IndexedContentIdentity(
        uri: row["uri"],
        cid: row["cid"],
        authorDid: row["author_did"],
        collection: row["collection"]
      )
    }
  }

  public func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws {
    let createdAtIso = Self.isoString(from: createdAt)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO read_marks (viewer_did, subject_uri, created_at)
          VALUES (?, ?, ?)
          ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = excluded.created_at
          """,
        arguments: [viewerDid, subjectUri, createdAtIso]
      )
      try db.execute(
        sql: "DELETE FROM appview_unread_overrides WHERE viewer_did = ? AND subject_uri = ?",
        arguments: [viewerDid, subjectUri]
      )
    }
  }

  public func deleteReadMark(viewerDid: String, subjectUri: String) async throws {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM read_marks WHERE viewer_did = ? AND subject_uri = ?",
        arguments: [viewerDid, subjectUri]
      )
    }
  }

  public func upsertReadMarks(
    viewerDid: String,
    subjectUris: [String],
    createdAt: Date
  ) async throws {
    let subjects = Array(Set(subjectUris)).sorted()
    guard !subjects.isEmpty else { return }
    let createdAtIso = Self.isoString(from: createdAt)
    let countedAt = Date()
    let generation = AppViewUnreadCounterSupport.generation(for: countedAt)
    let countedAtIso = Self.isoString(from: countedAt)
    try await db.write { db in
      for start in stride(from: 0, to: subjects.count, by: 500) {
        let batch = Array(subjects[start..<min(start + 500, subjects.count)])
        let values = Array(repeating: "(?)", count: batch.count).joined(separator: ", ")
        try db.execute(
          sql: """
            WITH subjects(subject_uri) AS (VALUES \(values))
            INSERT INTO read_marks (viewer_did, subject_uri, created_at)
            SELECT ?, subject_uri, ? FROM subjects WHERE true
            ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = excluded.created_at
            """,
          arguments: StatementArguments(batch + [viewerDid, createdAtIso])
        )
        let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
        try db.execute(
          sql: """
            DELETE FROM appview_unread_overrides
            WHERE viewer_did = ? AND subject_uri IN (\(placeholders))
            """,
          arguments: StatementArguments([viewerDid] + batch)
        )
        var counterArguments: [DatabaseValueConvertible?] = [
          generation, AppViewUnreadCounterAccuracy.estimated.rawValue, countedAtIso, viewerDid,
        ]
        counterArguments.append(contentsOf: batch)
        try db.execute(
          sql: """
            INSERT INTO appview_unread_counters
              (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
            SELECT DISTINCT scope.viewer_did, scope.publication_id, 0, ?, ?, 1, ?
            FROM appview_publication_scopes scope
            JOIN content_items ci ON ci.author_did = scope.author_did
              AND (
                json_array_length(scope.scope_keys) = 0
                OR EXISTS (SELECT 1 FROM json_each(scope.scope_keys) WHERE value = ci.publication_site)
              )
            WHERE scope.viewer_did = ? AND ci.uri IN (\(placeholders))
            ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
              generation = excluded.generation,
              accuracy = excluded.accuracy,
              dirty = 1,
              counted_at = excluded.counted_at
            """,
          arguments: StatementArguments(counterArguments)
        )
      }
    }
  }

  public func markEntryUnread(
    viewerDid: String,
    subjectUri: String,
    createdAt: Date
  ) async throws {
    let createdAtIso = Self.isoString(from: createdAt)
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM read_marks WHERE viewer_did = ? AND subject_uri = ?",
        arguments: [viewerDid, subjectUri]
      )
      try db.execute(
        sql: """
          INSERT INTO appview_unread_overrides (viewer_did, subject_uri, created_at)
          VALUES (?, ?, ?)
          ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = excluded.created_at
          """,
        arguments: [viewerDid, subjectUri, createdAtIso]
      )
    }
  }

  public func purgeReadMarks(viewerDid: String) async throws {
    try await db.write { db in
      try db.execute(sql: "DELETE FROM read_marks WHERE viewer_did = ?", arguments: [viewerDid])
      try db.execute(
        sql: "DELETE FROM appview_unread_overrides WHERE viewer_did = ?",
        arguments: [viewerDid]
      )
    }
  }

  public func fetchContentItem(uri: String) async throws -> AppViewEntryListItem? {
    let nowIso = Self.isoString(from: Date())
    let row: (uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)? =
      try await db.read { db in
      guard
        let fetched = try Row.fetchOne(
          db,
          sql: """
            SELECT ci.uri, ci.render_json, ci.created_at, ci.publication_site
            FROM content_items ci
            WHERE ci.uri = ? AND ci.expires_at > ?
            LIMIT 1
            """,
          arguments: [uri, nowIso]
        )
      else { return nil }
      return (
        uri: fetched["uri"],
        renderJSON: fetched["render_json"],
        createdAt: Self.date(fromIso: fetched["created_at"]) ?? Date.distantPast,
        publicationSite: fetched["publication_site"]
      )
    }
    guard let row else { return nil }
    let item = ThinAppViewQuerySupport.entryListItems(
      from: [(row.uri, row.renderJSON, row.createdAt)]
    ).first
    if let publicationSite = row.publicationSite {
      return item?.withPublicationId(publicationSite)
    }
    return item
  }

  public func fetchContentRender(uri: String) async throws -> ContentRenderFields? {
    let nowIso = Self.isoString(from: Date())
    let renderJSON: String? = try await db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT ci.render_json
          FROM content_items ci
          WHERE ci.uri = ? AND ci.expires_at > ?
          LIMIT 1
          """,
        arguments: [uri, nowIso]
      )
    }
    guard let renderJSON, let data = renderJSON.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ContentRenderFields.self, from: data)
  }

  public func listContentItemsForPublicationSite(
    authorDid: String,
    publicationSite: String,
    limit: Int
  ) async throws -> [(uri: String, renderJSON: String)] {
    let capped = max(1, min(limit, 2_000))
    let nowIso = Self.isoString(from: Date())
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT uri, render_json
          FROM content_items
          WHERE author_did = ?
            AND publication_site = ?
            AND expires_at > ?
          ORDER BY created_at DESC, uri DESC
          LIMIT ?
          """,
        arguments: [authorDid, publicationSite, nowIso, capped]
      )
      return rows.compactMap { row in
        guard
          let uri = row["uri"] as String?,
          let renderJSON = row["render_json"] as String?
        else { return nil }
        return (uri, renderJSON)
      }
    }
  }

  public func hasReadMark(viewerDid: String, subjectUri: String) async throws -> Bool {
    try await db.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT 1
          FROM read_marks
          WHERE viewer_did = ? AND subject_uri = ?
          LIMIT 1
          """,
        arguments: [viewerDid, subjectUri]
      ) != nil
    }
  }

  public func readStates(
    viewerDid: String,
    entries: [AppViewEntryListItem]
  ) async throws -> [String: Bool] {
    guard !entries.isEmpty else { return [:] }
    let entryIds = Array(Set(entries.map(\.entryId))).sorted()
    let publicationIds = Array(Set(entries.compactMap(\.publicationId))).sorted()
    return try await db.read { db in
      let entryPlaceholders = entryIds.map { _ in "?" }.joined(separator: ", ")
      let readRows = try String.fetchAll(
        db,
        sql: """
          SELECT subject_uri FROM read_marks
          WHERE viewer_did = ? AND subject_uri IN (\(entryPlaceholders))
          """,
        arguments: StatementArguments([viewerDid] + entryIds)
      )
      let overrideRows = try String.fetchAll(
        db,
        sql: """
          SELECT subject_uri FROM appview_unread_overrides
          WHERE viewer_did = ? AND subject_uri IN (\(entryPlaceholders))
          """,
        arguments: StatementArguments([viewerDid] + entryIds)
      )
      let explicitReads = Set(readRows)
      let unreadOverrides = Set(overrideRows)
      let floors = try Self.readBoundaries(
        viewerDid: viewerDid,
        publicationIds: publicationIds,
        db: db
      )
      return Dictionary(uniqueKeysWithValues: entries.map { entry in
        let covered = entry.publicationId
          .flatMap { floors[$0] }?
          .contains(createdAt: entry.feedPositionAt, entryId: entry.entryId) ?? false
        return (
          entry.entryId,
          explicitReads.contains(entry.entryId)
            || (covered && !unreadOverrides.contains(entry.entryId))
        )
      })
    }
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
    let nowIso = Self.isoString(from: Date())
    let pageLimit = max(1, min(limit, 100))
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

    if !scoped {
      let fetched = try await fetchContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        filter: filter,
        cursor: dbCursor,
        limit: batchSize,
        nowIso: nowIso,
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
        nowIso: nowIso,
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

  public func publicationScopes(
    viewerDid: String,
    sectionKey: String
  ) async throws -> [AppViewPublicationScope] {
    try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT viewer_did, publication_id, author_did, publication_at_uri,
                 publication_scope_at_uris, publication_site_urls, scope_keys,
                 section_keys, updated_at
          FROM appview_publication_scopes
          WHERE viewer_did = ?
          ORDER BY publication_id
          """,
        arguments: [viewerDid]
      )
      return rows
        .compactMap(Self.publicationScope(from:))
        .filter { $0.sectionKeys.contains(sectionKey) }
    }
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

    return try await db.read { db in
      var sql = """
        SELECT ci.uri, ci.author_did, ci.publication_site, ci.created_at,
               COALESCE(json_extract(ci.render_json, '$.title'), '') AS title,
               json_extract(ci.render_json, '$.publishedAt') AS published_at,
               json_extract(ci.render_json, '$.summary') AS summary,
               json_extract(ci.render_json, '$.thumbnailUrl') AS thumbnail_url,
               json_extract(ci.render_json, '$.articleUrl') AS article_url
        FROM content_items ci
        WHERE ci.author_did IN (\(authorDids.map { _ in "?" }.joined(separator: ", ")))
          AND ci.expires_at > ?
        """
      var arguments: [DatabaseValueConvertible?] = authorDids
      arguments.append(Self.isoString(from: Date()))

      if !unscopedAuthorDids.isEmpty || !scopeKeys.isEmpty {
        var membershipPredicates: [String] = []
        if !unscopedAuthorDids.isEmpty {
          membershipPredicates.append(
            "ci.author_did IN (\(unscopedAuthorDids.map { _ in "?" }.joined(separator: ", ")))"
          )
          arguments.append(contentsOf: unscopedAuthorDids)
        }
        if !scopeKeys.isEmpty {
          membershipPredicates.append(
            "ci.publication_site IN (\(scopeKeys.map { _ in "?" }.joined(separator: ", ")))"
          )
          arguments.append(contentsOf: scopeKeys)
        }
        sql += " AND (\(membershipPredicates.joined(separator: " OR ")))"
      }

      if let cursor {
        let cursorIso = Self.isoString(from: cursor.createdAt)
        sql += " AND (ci.created_at < ? OR (ci.created_at = ? AND ci.uri < ?))"
        arguments.append(contentsOf: [cursorIso, cursorIso, cursor.uri])
      }
      sql += " ORDER BY ci.created_at DESC, ci.uri DESC LIMIT ?"
      arguments.append(limit)

      return try Row.fetchAll(
        db,
        sql: sql,
        arguments: StatementArguments(arguments)
      ).compactMap { row in
        guard let createdAt = Self.date(fromIso: row["created_at"]) else { return nil }
        return AggregateFeedDatabaseRow(
          uri: row["uri"],
          authorDid: row["author_did"],
          publicationSite: row["publication_site"],
          createdAt: createdAt,
          title: row["title"],
          publishedAt: row["published_at"],
          summary: row["summary"],
          thumbnailUrl: row["thumbnail_url"],
          articleUrl: row["article_url"]
        )
      }
    }
  }

  private func fetchContentBatch(
    viewerDid: String,
    authorDid: String,
    filter: EntryListFilter,
    cursor: (createdAt: Date, uri: String)?,
    limit: Int,
    nowIso: String,
    readBoundary: ReadWatermarkBoundary?
  ) async throws -> [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] {
    try await db.read { db in
      let joinClause: String
      switch filter {
      case .all:
        joinClause = ""
      case .unread:
        joinClause = """

          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          LEFT JOIN appview_unread_overrides uo
            ON uo.viewer_did = ? AND uo.subject_uri = ci.uri
        """
      case .read:
        joinClause = """

          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          LEFT JOIN appview_unread_overrides uo
            ON uo.viewer_did = ? AND uo.subject_uri = ci.uri
        """
      }
      var sql = """
        SELECT ci.uri, ci.render_json, ci.created_at, ci.publication_site
        FROM content_items ci
        \(joinClause)
        WHERE ci.author_did = ?
          AND ci.expires_at > ?
        """

      var args: [DatabaseValueConvertible?] = []
      if filter != .all {
        args.append(contentsOf: [viewerDid, viewerDid])
      }
      args.append(contentsOf: [authorDid, nowIso])

      switch filter {
      case .all:
        break
      case .unread:
        sql += " AND rm.subject_uri IS NULL"
        if let readBoundary {
          let floorIso = Self.isoString(from: readBoundary.createdAt)
          if let entryId = readBoundary.entryId {
            sql += """
               AND (
                 ci.created_at > ?
                 OR (ci.created_at = ? AND ci.uri > ?)
                 OR uo.subject_uri IS NOT NULL
               )
              """
            args.append(contentsOf: [floorIso, floorIso, entryId])
          } else {
            sql += " AND (ci.created_at > ? OR uo.subject_uri IS NOT NULL)"
            args.append(floorIso)
          }
        }
      case .read:
        if let readBoundary {
          let floorIso = Self.isoString(from: readBoundary.createdAt)
          if let entryId = readBoundary.entryId {
            sql += """
               AND (
                 rm.subject_uri IS NOT NULL
                 OR (
                   uo.subject_uri IS NULL
                   AND (ci.created_at < ? OR (ci.created_at = ? AND ci.uri <= ?))
                 )
               )
              """
            args.append(contentsOf: [floorIso, floorIso, entryId])
          } else {
            sql += """
               AND (
                 rm.subject_uri IS NOT NULL
                 OR (uo.subject_uri IS NULL AND ci.created_at <= ?)
               )
              """
            args.append(floorIso)
          }
        } else {
          sql += " AND rm.subject_uri IS NOT NULL"
        }
      }

      if let decoded = cursor {
        sql += " AND (ci.created_at < ? OR (ci.created_at = ? AND ci.uri < ?))"
        let createdIso = Self.isoString(from: decoded.createdAt)
        args.append(contentsOf: [createdIso, createdIso, decoded.uri])
      }

      sql += " ORDER BY ci.created_at DESC, ci.uri DESC LIMIT ?"
      args.append(limit)

      let fetched = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
      return fetched.map { row in
        (
          uri: row["uri"],
          renderJSON: row["render_json"],
          createdAt: Self.date(fromIso: row["created_at"]) ?? Date.distantPast,
          publicationSite: row["publication_site"]
        )
      }
    }
  }

  public func listFeedEntries(
    viewerDid: String,
    selector: AppViewFeedSelector,
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewFeedPage? {
    let databaseStartedAt = Date()
    let projection: (updatedAt: Date, scopes: [PublicationUnreadScope])? = try await db.read { db in
      let updatedAtRaw: String?
      let scopeRows: [Row]
      if selector.kind == .publication {
        updatedAtRaw = try String.fetchOne(
          db,
          sql: """
            SELECT updated_at
            FROM appview_publication_scopes
            WHERE viewer_did = ?
              AND (
                publication_id = ? OR publication_at_uri = ?
                OR EXISTS (SELECT 1 FROM json_each(scope_keys) WHERE value = ?)
              )
            ORDER BY updated_at DESC
            LIMIT 1
            """,
          arguments: [viewerDid, selector.id, selector.id, selector.id]
        )
        scopeRows = try Row.fetchAll(
          db,
          sql: """
            SELECT viewer_did, publication_id, author_did, publication_at_uri,
                   publication_scope_at_uris, publication_site_urls, scope_keys,
                   section_keys, updated_at
            FROM appview_publication_scopes
            WHERE viewer_did = ?
              AND (
                publication_id = ? OR publication_at_uri = ?
                OR EXISTS (SELECT 1 FROM json_each(scope_keys) WHERE value = ?)
              )
            """,
          arguments: [viewerDid, selector.id, selector.id, selector.id]
        )
      } else {
        updatedAtRaw = try String.fetchOne(
          db,
          sql: """
            SELECT updated_at FROM appview_viewer_feeds
            WHERE viewer_did = ? AND feed_kind = ? AND feed_id = ?
            LIMIT 1
            """,
          arguments: [viewerDid, selector.kind.rawValue, selector.id]
        )
        scopeRows = try Row.fetchAll(
          db,
          sql: """
            SELECT scope.viewer_did, scope.publication_id, scope.author_did,
                   scope.publication_at_uri, scope.publication_scope_at_uris,
                   scope.publication_site_urls, scope.scope_keys, scope.section_keys,
                   scope.updated_at
            FROM appview_feed_publications membership
            JOIN appview_publication_scopes scope
              ON scope.viewer_did = membership.viewer_did
             AND scope.publication_id = membership.publication_id
            WHERE membership.viewer_did = ?
              AND membership.feed_kind = ?
              AND membership.feed_id = ?
            """,
          arguments: [viewerDid, selector.kind.rawValue, selector.id]
        )
      }
      guard let updatedAtRaw, let updatedAt = Self.date(fromIso: updatedAtRaw) else { return nil }
      let scopes = scopeRows.compactMap(Self.publicationScope(from:)).map { scope in
        PublicationUnreadScope(
          publicationId: scope.publicationId,
          authorDid: scope.authorDid,
          publicationAtUri: scope.publicationAtUri,
          publicationScopeAtUris: scope.publicationScopeAtUris,
          publicationSiteUrls: scope.publicationSiteUrls
        )
      }
      return (updatedAt, scopes)
    }
    guard let projection else { return nil }
    let response = try await listFeedEntries(
      viewerDid: viewerDid,
      scopes: projection.scopes,
      filter: filter,
      cursor: cursor,
      limit: limit
    )
    let states = try await readStates(viewerDid: viewerDid, entries: response.entries)
    return AppViewFeedPage(
      response: AppViewEntryListResponse(
        entries: response.entries.map {
          $0.withReadState(states[$0.entryId] ?? false)
        },
        cursor: response.cursor
      ),
      membershipUpdatedAt: projection.updatedAt,
      databaseDurationMilliseconds: Date().timeIntervalSince(databaseStartedAt) * 1_000
    )
  }

  public func hasViewerFeedProjection(viewerDid: String) async throws -> Bool {
    try await db.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT 1 FROM appview_viewer_feeds WHERE viewer_did = ?
          UNION ALL
          SELECT 1 FROM appview_publication_scopes WHERE viewer_did = ?
          LIMIT 1
          """,
        arguments: [viewerDid, viewerDid]
      ) != nil
    }
  }

  public func countUnreadEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> Int {
    let nowIso = Self.isoString(from: Date())
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )

    if !scoped {
      return try await db.read { db in
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*)
            FROM content_items ci
            LEFT JOIN read_marks rm
              ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
            WHERE ci.author_did = ?
              AND ci.expires_at > ?
              AND rm.subject_uri IS NULL
            """,
          arguments: [viewerDid, authorDid, nowIso]
        ) ?? 0
      }
    }

    let siteFields: [String?] = try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ci.publication_site
          FROM content_items ci
          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          WHERE ci.author_did = ?
            AND ci.expires_at > ?
            AND rm.subject_uri IS NULL
          """,
        arguments: [viewerDid, authorDid, nowIso]
      )
      return rows.map { $0["publication_site"] as String? }
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
    let nowIso = Self.isoString(from: Date())
    let placeholders = authorDids.map { _ in "?" }.joined(separator: ", ")

    let unreadSiteCountsByAuthor: [String: [UnreadSiteCount]] = try await db.read { db in
      var grouped: [String: [UnreadSiteCount]] = Dictionary(
        uniqueKeysWithValues: authorDids.map { ($0, []) }
      )
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ci.author_did, ci.publication_site, COUNT(*) AS unread_count
          FROM content_items ci
          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          WHERE ci.author_did IN (\(placeholders))
            AND ci.expires_at > ?
            AND rm.subject_uri IS NULL
          GROUP BY ci.author_did, ci.publication_site
          """,
        arguments: StatementArguments([viewerDid] + authorDids + [nowIso])
      )
      for row in rows {
        let authorDid: String = row["author_did"]
        grouped[authorDid, default: []].append(
          UnreadSiteCount(site: row["publication_site"] as String?, count: row["unread_count"])
        )
      }
      return grouped
    }

    return ThinAppViewQuerySupport.batchUnreadCounts(
      scopes: scopes,
      unreadSiteCountsByAuthor: unreadSiteCountsByAuthor
    )
  }

  public func upsertPublicationScopes(_ scopes: [AppViewPublicationScope]) async throws {
    guard !scopes.isEmpty else { return }
    try await db.write { db in
      for scope in scopes {
        try db.execute(
          sql: """
            INSERT INTO appview_publication_scopes
              (viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris, publication_site_urls, scope_keys,
               section_keys, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
              author_did = excluded.author_did,
              publication_at_uri = excluded.publication_at_uri,
              publication_scope_at_uris = excluded.publication_scope_at_uris,
              publication_site_urls = excluded.publication_site_urls,
              scope_keys = excluded.scope_keys,
              section_keys = excluded.section_keys,
              updated_at = excluded.updated_at
            """,
          arguments: [
            scope.viewerDid,
            scope.publicationId,
            scope.authorDid,
            scope.publicationAtUri,
            try Self.jsonString(scope.publicationScopeAtUris),
            try Self.jsonString(scope.publicationSiteUrls),
            try Self.jsonString(scope.scopeKeys),
            try Self.jsonString(scope.sectionKeys),
            Self.isoString(from: scope.updatedAt),
          ]
        )
      }
    }
  }

  public func replacePublicationScopes(
    viewerDid: String,
    scopes: [AppViewPublicationScope]
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM appview_publication_scopes WHERE viewer_did = ?",
        arguments: [viewerDid]
      )
      for scope in scopes {
        try db.execute(
          sql: """
            INSERT INTO appview_publication_scopes
              (viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris, publication_site_urls, scope_keys,
               section_keys, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
              author_did = excluded.author_did,
              publication_at_uri = excluded.publication_at_uri,
              publication_scope_at_uris = excluded.publication_scope_at_uris,
              publication_site_urls = excluded.publication_site_urls,
              scope_keys = excluded.scope_keys,
              section_keys = excluded.section_keys,
              updated_at = excluded.updated_at
            """,
          arguments: [
            scope.viewerDid,
            scope.publicationId,
            scope.authorDid,
            scope.publicationAtUri,
            try Self.jsonString(scope.publicationScopeAtUris),
            try Self.jsonString(scope.publicationSiteUrls),
            try Self.jsonString(scope.scopeKeys),
            try Self.jsonString(scope.sectionKeys),
            Self.isoString(from: scope.updatedAt),
          ]
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
    try await db.write { db in
      try Self.writeViewerFeedProjection(
        scopes: scopes,
        feeds: feeds,
        memberships: memberships,
        db: db
      )
    }
    _ = viewerDid
  }

  public func replaceViewerFeedProjection(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    feeds: [AppViewViewerFeed],
    memberships: [AppViewFeedPublication]
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM appview_feed_publications WHERE viewer_did = ?",
        arguments: [viewerDid]
      )
      try db.execute(
        sql: "DELETE FROM appview_viewer_feeds WHERE viewer_did = ?",
        arguments: [viewerDid]
      )
      try db.execute(
        sql: "DELETE FROM appview_publication_scopes WHERE viewer_did = ?",
        arguments: [viewerDid]
      )
      try Self.writeViewerFeedProjection(
        scopes: scopes,
        feeds: feeds,
        memberships: memberships,
        db: db
      )
    }
  }

  public func fetchUnreadCounters(
    viewerDid: String,
    publicationIds: [String]?
  ) async throws -> [AppViewUnreadCounter] {
    try await db.read { db in
      var sql = """
        SELECT publication_id, unread_count, generation, accuracy, dirty, counted_at
        FROM appview_unread_counters
        WHERE viewer_did = ?
        """
      var args: [DatabaseValueConvertible?] = [viewerDid]
      if let publicationIds, !publicationIds.isEmpty {
        sql += " AND publication_id IN (\(publicationIds.map { _ in "?" }.joined(separator: ", ")))"
        args.append(contentsOf: publicationIds)
      }
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
      return rows.compactMap(Self.unreadCounter(from:))
    }
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
    let countedAtIso = Self.isoString(from: countedAt)
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
      counters.append(
        AppViewUnreadCounter(
          publicationId: scope.publicationId,
          unreadCount: count,
          generation: generation,
          accuracy: .exact,
          dirty: false,
          countedAt: countedAt
        )
      )
    }

    let countersToStore = counters
    try await db.write { db in
      for counter in countersToStore {
        try Self.upsertUnreadCounter(counter, viewerDid: viewerDid, countedAtIso: countedAtIso, db: db)
      }
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
    let countedAt = Self.isoString(from: Date())
    try await db.write { db in
      for scope in scopes {
        if let boundary = try Self.readBoundary(
          viewerDid: scope.viewerDid,
          publicationId: scope.publicationId,
          db: db
        ),
          boundary.contains(createdAt: item.createdAt, entryId: item.uri),
          try !Self.hasUnreadOverride(viewerDid: scope.viewerDid, subjectUri: item.uri, db: db)
        {
          continue
        }
        let alreadyRead = try Bool.fetchOne(
          db,
          sql: """
            SELECT 1
            FROM read_marks
            WHERE viewer_did = ? AND subject_uri = ?
            LIMIT 1
            """,
          arguments: [scope.viewerDid, item.uri]
        ) != nil
        guard !alreadyRead else { continue }
        try Self.adjustUnreadCounter(
          viewerDid: scope.viewerDid,
          publicationId: scope.publicationId,
          delta: 1,
          generation: generation,
          countedAtIso: countedAt,
          db: db
        )
      }
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
    let countedAt = Self.isoString(from: Date())
    try await db.write { db in
      for scope in scopes {
        try Self.markUnreadCounterDirty(
          viewerDid: scope.viewerDid,
          publicationId: scope.publicationId,
          generation: generation,
          countedAtIso: countedAt,
          db: db
        )
      }
    }
  }

  public func markUnreadCountersDirtyForAuthor(authorDid: String) async throws {
    let scopes = try await publicationScopes(authorDid: authorDid, viewerDid: nil)
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Self.isoString(from: Date())
    try await db.write { db in
      for scope in scopes {
        try Self.markUnreadCounterDirty(
          viewerDid: scope.viewerDid,
          publicationId: scope.publicationId,
          generation: generation,
          countedAtIso: countedAt,
          db: db
        )
      }
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
    let countedAt = Self.isoString(from: Date())
    try await db.write { db in
      for scope in scopes {
        try Self.adjustUnreadCounter(
          viewerDid: viewerDid,
          publicationId: scope.publicationId,
          delta: delta,
          generation: generation,
          countedAtIso: countedAt,
          db: db
        )
      }
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
    let readAtIso = Self.isoString(from: readAt)
    return try await db.write { db in
      var counters: [AppViewUnreadCounter] = []
      var boundaries: [ReadWatermarkBoundary] = []
      for scope in uniqueScopes {
        let requested = try Self.newestBoundary(scope: scope, fallback: readAt, db: db)
        let existing = try Self.readBoundary(
          viewerDid: viewerDid,
          publicationId: scope.publicationId,
          db: db
        )
        let confirmed = existing.map { requested.isAfter($0) ? requested : $0 } ?? requested
        try db.execute(
          sql: """
            INSERT INTO appview_publication_read_floors
              (viewer_did, publication_id, read_floor_at, read_floor_uri, generation, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
              read_floor_at = excluded.read_floor_at,
              read_floor_uri = excluded.read_floor_uri,
              generation = excluded.generation,
              updated_at = excluded.updated_at
            """,
          arguments: [
            viewerDid,
            scope.publicationId,
            Self.isoString(from: confirmed.createdAt),
            confirmed.entryId,
            generation,
            readAtIso,
          ]
        )
        try Self.deleteCoveredUnreadOverrides(
          viewerDid: viewerDid,
          scope: scope,
          boundary: confirmed,
          createdBeforeOrAt: readAtIso,
          db: db
        )
        let nowIso = Self.isoString(from: Date())
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
        let floorIso = Self.isoString(from: confirmed.createdAt)
        let unreadCount: Int
        if scoped, siteKeys.isEmpty {
          unreadCount = 0
        } else {
          var sql = """
            SELECT COUNT(*)
            FROM content_items ci
            LEFT JOIN read_marks rm
              ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
            LEFT JOIN appview_unread_overrides uo
              ON uo.viewer_did = ? AND uo.subject_uri = ci.uri
            WHERE ci.author_did = ?
              AND ci.expires_at > ?
              AND (
                ci.created_at > ?
                OR (? IS NOT NULL AND ci.created_at = ? AND ci.uri > ?)
                OR uo.subject_uri IS NOT NULL
              )
              AND rm.subject_uri IS NULL
            """
          var arguments: [DatabaseValueConvertible?] = [
            viewerDid,
            viewerDid,
            scope.authorDid,
            nowIso,
            floorIso,
            confirmed.entryId,
            floorIso,
            confirmed.entryId,
          ]
          if scoped {
            sql += " AND ci.publication_site IN (\(siteKeys.map { _ in "?" }.joined(separator: ", ")))"
            arguments.append(contentsOf: siteKeys)
          }
          unreadCount = try Int.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments(arguments)
          ) ?? 0
        }
        let counter = AppViewUnreadCounter(
          publicationId: scope.publicationId,
          unreadCount: unreadCount,
          generation: generation,
          accuracy: .exact,
          dirty: false,
          countedAt: readAt
        )
        try Self.upsertUnreadCounter(
          counter,
          viewerDid: viewerDid,
          countedAtIso: readAtIso,
          db: db
        )
        counters.append(counter)
        boundaries.append(confirmed)
      }
      // Mirrors PostgresThinAppViewStore: overrides whose content_items row has
      // TTL-expired can never match the per-scope INNER JOIN above, so they would
      // otherwise linger and resurrect stale unread state when the same
      // deterministic URI is re-indexed.
      try db.execute(
        sql: """
          DELETE FROM appview_unread_overrides
          WHERE viewer_did = ?
            AND created_at <= ?
            AND subject_uri NOT IN (SELECT uri FROM content_items)
          """,
        arguments: [viewerDid, readAtIso]
      )
      return (counters, boundaries)
    }
  }

  public func readBoundary(
    viewerDid: String,
    publicationId: String
  ) async throws -> ReadWatermarkBoundary? {
    try await db.read { db in
      try Self.readBoundary(viewerDid: viewerDid, publicationId: publicationId, db: db)
    }
  }

  public func deleteExpiredContent(before: Date, batchSize: Int) async throws -> Int {
    let beforeIso = Self.isoString(from: before)
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM content_items
          WHERE rowid IN (
            SELECT rowid FROM content_items
            WHERE expires_at <= ?
            ORDER BY expires_at, uri
            LIMIT ?
          )
          """,
        arguments: [beforeIso, batchSize]
      )
      return db.changesCount
    }
  }

  public func deleteExpiredReadMarks(before: Date, batchSize: Int) async throws -> Int {
    let beforeIso = Self.isoString(from: before)
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM read_marks
          WHERE rowid IN (
            SELECT rowid FROM read_marks
            WHERE created_at <= ?
            ORDER BY created_at, viewer_did, subject_uri
            LIMIT ?
          )
          """,
        arguments: [beforeIso, batchSize]
      )
      return db.changesCount
    }
  }

  public func deleteExpiredTapEventReceipts(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM appview_tap_event_receipts
          WHERE rowid IN (
            SELECT rowid FROM appview_tap_event_receipts
            WHERE environment = ? AND expires_at <= ?
            ORDER BY expires_at, event_id
            LIMIT ?
          )
          """,
        arguments: [environment, Self.isoString(from: before), batchSize]
      )
      return db.changesCount
    }
  }

  public func deleteExpiredProjectionRepairs(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM appview_projection_repair_outbox
          WHERE rowid IN (
            SELECT rowid FROM appview_projection_repair_outbox
            WHERE environment = ? AND status = 'failed' AND expires_at <= ?
            ORDER BY expires_at, id
            LIMIT ?
          )
          """,
        arguments: [environment, Self.isoString(from: before), batchSize]
      )
      return db.changesCount
    }
  }

  public func desiredTapRepositoryScope(limit: Int) async throws -> TapDesiredRepositoryScope {
    let limit = max(1, min(limit, 10_000))
    return try await db.read { db in
      let scanBatchSize = 500
      var rows: [String] = []
      var after = ""
      while rows.count <= limit {
        let page = try String.fetchAll(
          db,
          sql: """
            SELECT DISTINCT author_did
            FROM appview_publication_scopes
            WHERE author_did > ?
            ORDER BY author_did
            LIMIT ?
            """,
          arguments: [after, scanBatchSize]
        )
        guard let last = page.last else { break }
        rows.append(contentsOf: page.filter(ATProtoRepositoryDIDValidator.isValid))
        after = last
        if page.count < scanBatchSize { break }
      }
      return TapDesiredRepositoryScope(
        repoDids: Array(rows.prefix(limit)),
        truncated: rows.count > limit
      )
    }
  }

  public func registeredTapRepositoryDids(environment: String) async throws -> [String] {
    try await db.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT repo_did
          FROM appview_tap_repository_registrations
          WHERE environment = ? AND is_registered = 1
          ORDER BY repo_did
          """,
        arguments: [environment]
      )
    }
  }

  public func markTapRepositoriesRegistered(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws {
    guard !repoDids.isEmpty else { return }
    let timestamp = Self.isoString(from: at)
    try await db.write { db in
      for repoDid in repoDids {
        try db.execute(
          sql: """
            INSERT INTO appview_tap_repository_registrations
              (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
            VALUES (?, ?, 1, ?, NULL, ?)
            ON CONFLICT (environment, repo_did) DO UPDATE SET
              is_registered = 1,
              registered_at = excluded.registered_at,
              removed_at = NULL,
              updated_at = excluded.updated_at
            """,
          arguments: [environment, repoDid, timestamp, timestamp]
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
    let timestamp = Self.isoString(from: at)
    try await db.write { db in
      for repoDid in repoDids {
        try db.execute(
          sql: """
            INSERT INTO appview_tap_repository_registrations
              (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
            VALUES (?, ?, 0, NULL, ?, ?)
            ON CONFLICT (environment, repo_did) DO UPDATE SET
              is_registered = 0,
              removed_at = excluded.removed_at,
              updated_at = excluded.updated_at
            """,
          arguments: [environment, repoDid, timestamp, timestamp]
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
    let eventTimeIso = eventTime.map { Self.isoString(from: $0) }
    let observedAtIso = Self.isoString(from: observedAt)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_checkpoints
            (environment, source, repo_did, collection, cursor, event_time, observed_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, source, repo_did, collection) DO UPDATE SET
            cursor = excluded.cursor,
            event_time = excluded.event_time,
            observed_at = excluded.observed_at
          """,
        arguments: [
          environment,
          source,
          repoDid,
          collection,
          cursor,
          eventTimeIso,
          observedAtIso,
        ]
      )
    }
  }

  public func fetchTapRepositorySyncState(
    environment: String,
    repoDid: String
  ) async throws -> TapRepositorySyncState? {
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT repo_rev, account_status, pds_base, last_event_id, last_event_live,
                 parity_status, matched_event_count, mismatched_event_count,
                 last_mismatch, last_indexed_at, last_validated_at, updated_at
          FROM appview_tap_repo_state
          WHERE environment = ? AND repo_did = ?
          LIMIT 1
          """,
        arguments: [environment, repoDid]
      ) else { return nil }
      guard
        let accountStatus = TapAccountStatus(rawValue: row["account_status"]),
        let parityStatus = TapParityStatus(rawValue: row["parity_status"]),
        let updatedAt = Self.date(fromIso: row["updated_at"])
      else { return nil }
      let liveInteger: Int? = row["last_event_live"]
      return TapRepositorySyncState(
        environment: environment,
        repoDid: repoDid,
        repoRev: row["repo_rev"],
        accountStatus: accountStatus,
        pdsBase: row["pds_base"],
        lastEventId: row["last_event_id"],
        lastEventLive: liveInteger.map { $0 != 0 } ?? false,
        parityStatus: parityStatus,
        matchedEventCount: row["matched_event_count"],
        mismatchedEventCount: row["mismatched_event_count"],
        lastMismatch: row["last_mismatch"],
        lastIndexedAt: (row["last_indexed_at"] as String?).flatMap(Self.date(fromIso:)),
        lastValidatedAt: (row["last_validated_at"] as String?).flatMap(Self.date(fromIso:)),
        updatedAt: updatedAt
      )
    }
  }

  public func upsertTapRepositorySyncState(_ state: TapRepositorySyncState) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_tap_repo_state
            (environment, repo_did, repo_rev, account_status, pds_base,
             last_event_id, last_event_live, parity_status, matched_event_count,
             mismatched_event_count, last_mismatch, last_indexed_at,
             last_validated_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            repo_rev = excluded.repo_rev,
            account_status = excluded.account_status,
            pds_base = excluded.pds_base,
            last_event_id = excluded.last_event_id,
            last_event_live = excluded.last_event_live,
            parity_status = excluded.parity_status,
            matched_event_count = excluded.matched_event_count,
            mismatched_event_count = excluded.mismatched_event_count,
            last_mismatch = excluded.last_mismatch,
            last_indexed_at = excluded.last_indexed_at,
            last_validated_at = excluded.last_validated_at,
            updated_at = excluded.updated_at
          """,
        arguments: [
          state.environment,
          state.repoDid,
          state.repoRev,
          state.accountStatus.rawValue,
          state.pdsBase,
          state.lastEventId,
          state.lastEventLive ? 1 : 0,
          state.parityStatus.rawValue,
          state.matchedEventCount,
          state.mismatchedEventCount,
          state.lastMismatch,
          state.lastIndexedAt.map(Self.isoString(from:)),
          state.lastValidatedAt.map(Self.isoString(from:)),
          Self.isoString(from: state.updatedAt),
        ]
      )
    }
  }

  public func hasProcessedTapEvent(environment: String, eventId: Int64) async throws -> Bool {
    try await db.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM appview_tap_event_receipts
            WHERE environment = ? AND event_id = ?
          )
          """,
        arguments: [environment, eventId]
      ) ?? false
    }
  }

  public func commitTapEvent(
    state: TapRepositorySyncState,
    eventId: Int64,
    eventType: String,
    parityEvidence: TapParityEventEvidence?,
    processedAt: Date
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_tap_repo_state
            (environment, repo_did, repo_rev, account_status, pds_base,
             last_event_id, last_event_live, parity_status, matched_event_count,
             mismatched_event_count, last_mismatch, last_indexed_at,
             last_validated_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            repo_rev = excluded.repo_rev,
            account_status = excluded.account_status,
            pds_base = excluded.pds_base,
            last_event_id = excluded.last_event_id,
            last_event_live = excluded.last_event_live,
            parity_status = excluded.parity_status,
            matched_event_count = excluded.matched_event_count,
            mismatched_event_count = excluded.mismatched_event_count,
            last_mismatch = excluded.last_mismatch,
            last_indexed_at = excluded.last_indexed_at,
            last_validated_at = excluded.last_validated_at,
            updated_at = excluded.updated_at
          """,
        arguments: Self.tapStateArguments(state)
      )
      try db.execute(
        sql: """
          INSERT INTO appview_tap_event_receipts
            (environment, event_id, repo_did, event_type, processed_at, expires_at)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, event_id) DO NOTHING
          """,
        arguments: [
          state.environment,
          eventId,
          state.repoDid,
          eventType,
          Self.isoString(from: processedAt),
          Self.isoString(from: processedAt.addingTimeInterval(30 * 86_400)),
        ]
      )
      if let parityEvidence {
        if let mismatchKind = parityEvidence.mismatchKind {
          try db.execute(
            sql: """
              INSERT INTO appview_tap_parity_discrepancies
                (environment, event_id, repo_did, uri, collection, mismatch_kind,
                 expected_cid, observed_cid, status, opened_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', ?)
              ON CONFLICT (environment, event_id) DO NOTHING
              """,
            arguments: [
              state.environment, eventId, state.repoDid, parityEvidence.uri,
              parityEvidence.collection, mismatchKind, parityEvidence.expectedCid,
              parityEvidence.observedCid, Self.isoString(from: processedAt),
            ]
          )
        } else {
          try db.execute(
            sql: """
              UPDATE appview_tap_parity_discrepancies
              SET status = 'resolved', resolved_at = ?, resolution_event_id = ?
              WHERE environment = ? AND repo_did = ? AND uri = ? AND status = 'open'
              """,
            arguments: [
              Self.isoString(from: processedAt), eventId, state.environment, state.repoDid,
              parityEvidence.uri,
            ]
          )
        }
        let openCount = try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM appview_tap_parity_discrepancies
            WHERE environment = ? AND repo_did = ? AND status = 'open'
            """,
          arguments: [state.environment, state.repoDid]
        ) ?? 0
        try db.execute(
          sql: """
            UPDATE appview_tap_repo_state
            SET parity_status = ?,
                last_mismatch = CASE WHEN ? = 0 THEN NULL ELSE last_mismatch END
            WHERE environment = ? AND repo_did = ?
            """,
          arguments: [
            openCount == 0 ? TapParityStatus.matched.rawValue : TapParityStatus.mismatch.rawValue,
            openCount, state.environment, state.repoDid,
          ]
        )
      }
    }
  }

  public func listTapParityDiscrepancies(
    environment: String,
    repoDid: String
  ) async throws -> [TapParityDiscrepancy] {
    try await db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, uri, collection, mismatch_kind, expected_cid, observed_cid,
                 status, opened_at, resolved_at, resolution_event_id
          FROM appview_tap_parity_discrepancies
          WHERE environment = ? AND repo_did = ?
          ORDER BY event_id
          """,
        arguments: [environment, repoDid]
      ).compactMap { row in
        guard
          let status = TapParityDiscrepancyStatus(rawValue: row["status"]),
          let openedAt = Self.date(fromIso: row["opened_at"])
        else { return nil }
        let resolvedRaw: String? = row["resolved_at"]
        return TapParityDiscrepancy(
          environment: environment,
          eventId: row["event_id"],
          repoDid: repoDid,
          uri: row["uri"],
          collection: row["collection"],
          mismatchKind: row["mismatch_kind"],
          expectedCid: row["expected_cid"],
          observedCid: row["observed_cid"],
          status: status,
          openedAt: openedAt,
          resolvedAt: resolvedRaw.flatMap(Self.date(fromIso:)),
          resolutionEventId: row["resolution_event_id"]
        )
      }
    }
  }

  public func applyTapContentMutation(
    _ mutation: TapContentMutation,
    environment: String,
    eventId: Int64,
    repoRev: String,
    eventTime: Date,
    observedAt: Date
  ) async throws {
    try await db.write { db in
      let publicationSite: String?
      let action: String
      switch mutation {
      case .upsert(let item):
        publicationSite = item.publicationSite
        action = "upsert"
        try db.execute(
          sql: """
            INSERT INTO content_items
              (uri, cid, author_did, collection, created_at, indexed_at,
               publication_site, render_json, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (uri) DO UPDATE SET
              cid = excluded.cid,
              author_did = excluded.author_did,
              collection = excluded.collection,
              created_at = excluded.created_at,
              indexed_at = excluded.indexed_at,
              publication_site = excluded.publication_site,
              render_json = excluded.render_json,
              expires_at = excluded.expires_at
            """,
          arguments: [
            item.uri,
            item.cid,
            item.authorDid,
            item.collection,
            Self.isoString(from: item.createdAt),
            Self.isoString(from: item.indexedAt),
            item.publicationSite,
            try item.render.encodedJSON(),
            Self.isoString(from: item.expiresAt),
          ]
        )
      case .delete(let uri, _, _):
        publicationSite = try String.fetchOne(
          db,
          sql: "SELECT publication_site FROM content_items WHERE uri = ?",
          arguments: [uri]
        )
        action = "delete"
        try db.execute(sql: "DELETE FROM content_items WHERE uri = ?", arguments: [uri])
      }

      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_checkpoints
            (environment, source, repo_did, collection, cursor, event_time, observed_at)
          VALUES (?, 'tap', ?, ?, ?, ?, ?)
          ON CONFLICT (environment, source, repo_did, collection) DO UPDATE SET
            cursor = excluded.cursor,
            event_time = excluded.event_time,
            observed_at = excluded.observed_at
          """,
        arguments: [
          environment,
          mutation.authorDid,
          mutation.collection,
          String(eventId),
          Self.isoString(from: eventTime),
          Self.isoString(from: observedAt),
        ]
      )

      let repairId = "\(environment):\(eventId)"
      let nowIso = Self.isoString(from: observedAt)
      try db.execute(
        sql: """
          INSERT INTO appview_projection_repair_outbox
            (id, environment, event_id, uri, author_did, publication_site, action,
             status, attempts, next_attempt_at, created_at, updated_at, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?, ?, ?, ?)
          ON CONFLICT (environment, event_id) DO NOTHING
          """,
        arguments: [
          repairId,
          environment,
          eventId,
          mutation.uri,
          mutation.authorDid,
          publicationSite,
          action,
          nowIso,
          nowIso,
          nowIso,
          Self.isoString(from: observedAt.addingTimeInterval(30 * 86_400)),
        ]
      )
      _ = repoRev
    }
  }

  public func projectionRepairBacklog(
    environment: String,
    at: Date
  ) async throws -> AppViewProjectionRepairBacklogSnapshot {
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            COUNT(CASE WHEN status = 'queued' THEN 1 END) AS queued_count,
            COUNT(CASE WHEN status = 'running' THEN 1 END) AS running_count,
            COUNT(CASE WHEN status = 'failed' THEN 1 END) AS failed_count,
            MIN(CASE WHEN status IN ('queued', 'running', 'failed') THEN created_at END)
              AS oldest_actionable_at
          FROM appview_projection_repair_outbox
          WHERE environment = ?
          """,
        arguments: [environment]
      ) else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }

      let queuedCount: Int = row["queued_count"]
      let runningCount: Int = row["running_count"]
      let failedCount: Int = row["failed_count"]
      let hasActionableRepairs = queuedCount > 0 || runningCount > 0 || failedCount > 0
      let oldestRaw: String? = row["oldest_actionable_at"]
      let oldestActionableAt = oldestRaw.flatMap(Self.date(fromIso:))

      guard queuedCount >= 0, runningCount >= 0, failedCount >= 0 else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      if hasActionableRepairs {
        guard oldestRaw != nil, let oldestActionableAt, oldestActionableAt <= at else {
          throw AppViewProjectionRepairError.invalidBacklogEvidence
        }
      } else if oldestRaw != nil {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }

      return AppViewProjectionRepairBacklogSnapshot(
        environment: environment,
        queuedCount: queuedCount,
        runningCount: runningCount,
        failedCount: failedCount,
        oldestActionableAt: oldestActionableAt,
        oldestActionableAgeSeconds: oldestActionableAt.map { at.timeIntervalSince($0) },
        observedAt: at
      )
    }
  }

  public func claimProjectionRepair(
    environment: String,
    workerId: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> AppViewProjectionRepair? {
    try await db.write { db in
      let atIso = Self.isoString(from: at)
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT id, environment, event_id, uri, author_did, publication_site,
                 action, attempts
          FROM appview_projection_repair_outbox
          WHERE environment = ?
            AND ((status = 'queued' AND next_attempt_at <= ?)
              OR (status = 'running' AND lease_until <= ?))
          ORDER BY created_at ASC
          LIMIT 1
          """,
        arguments: [environment, atIso, atIso]
      ) else { return nil }
      let id: String = row["id"]
      try db.execute(
        sql: """
          UPDATE appview_projection_repair_outbox
          SET status = 'running', lease_owner = ?, lease_until = ?, updated_at = ?
          WHERE environment = ? AND id = ?
          """,
        arguments: [workerId, Self.isoString(from: leaseUntil), atIso, environment, id]
      )
      return AppViewProjectionRepair(
        id: id,
        environment: row["environment"],
        eventId: row["event_id"],
        uri: row["uri"],
        authorDid: row["author_did"],
        publicationSite: row["publication_site"],
        action: row["action"],
        attempts: row["attempts"],
        leaseOwner: workerId,
        leaseUntil: leaseUntil
      )
    }
  }

  public func completeProjectionRepair(
    environment: String,
    id: String,
    workerId: String
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM appview_projection_repair_outbox
          WHERE environment = ? AND id = ? AND status = 'running' AND lease_owner = ?
          """,
        arguments: [environment, id, workerId]
      )
      guard db.changesCount == 1 else { throw AppViewProjectionRepairError.staleLease }
    }
  }

  public func failProjectionRepair(
    environment: String,
    id: String,
    workerId: String,
    errorCategory: String,
    retryAt: Date,
    at: Date
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          UPDATE appview_projection_repair_outbox
          SET attempts = attempts + 1,
              status = CASE WHEN attempts + 1 >= 5 THEN 'failed' ELSE 'queued' END,
              lease_owner = NULL,
              lease_until = NULL,
              next_attempt_at = ?,
              last_error = ?,
              updated_at = ?
          WHERE environment = ? AND id = ? AND status = 'running' AND lease_owner = ?
          """,
        arguments: [
          Self.isoString(from: retryAt), errorCategory, Self.isoString(from: at),
          environment, id, workerId,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewProjectionRepairError.staleLease }
    }
  }

  public func listAuthorDidsForProactiveBackfill(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 500))
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT author_did
          FROM content_items
          WHERE author_did LIKE 'did:%' AND author_did NOT LIKE 'did:web:%'
          GROUP BY author_did
          ORDER BY MAX(indexed_at) ASC
          LIMIT ?
          """,
        arguments: [capped]
      )
      return rows.compactMap { $0["author_did"] as String? }
    }
  }

  public func listRssPublicationSites(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 200))
    let nowIso = Self.isoString(from: Date())
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT publication_site
          FROM content_items
          WHERE author_did = ?
            AND publication_site IS NOT NULL
            AND expires_at > ?
          GROUP BY publication_site
          ORDER BY MIN(indexed_at) ASC
          LIMIT ?
          """,
        arguments: [RssFeedLexicons.rssAuthorDid, nowIso, capped]
      )
      return rows.compactMap { $0["publication_site"] as String? }
    }
  }

  public func fetchRssFeedMetadata(normalizedFeedUrl: String) async throws -> RssFeedFetchMetadata? {
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT etag, last_modified, last_poll_at, backoff_until, consecutive_error_count
          FROM rss_feed_fetch_metadata
          WHERE feed_url = ?
          LIMIT 1
          """,
        arguments: [normalizedFeedUrl]
      ) else {
        return nil
      }
      return RssFeedFetchMetadata(
        normalizedFeedUrl: normalizedFeedUrl,
        etag: row["etag"] as String?,
        lastModified: row["last_modified"] as String?,
        lastPollAt: (row["last_poll_at"] as String?).flatMap(Self.date(fromIso:)),
        backoffUntil: (row["backoff_until"] as String?).flatMap(Self.date(fromIso:)),
        consecutiveErrorCount: row["consecutive_error_count"]
      )
    }
  }

  public func storeRssFeedMetadata(_ metadata: RssFeedFetchMetadata) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO rss_feed_fetch_metadata
            (feed_url, etag, last_modified, last_poll_at, backoff_until, consecutive_error_count)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (feed_url) DO UPDATE SET
            etag = excluded.etag,
            last_modified = excluded.last_modified,
            last_poll_at = excluded.last_poll_at,
            backoff_until = excluded.backoff_until,
            consecutive_error_count = excluded.consecutive_error_count
          """,
        arguments: [
          metadata.normalizedFeedUrl,
          metadata.etag,
          metadata.lastModified,
          metadata.lastPollAt.map { Self.isoString(from: $0) },
          metadata.backoffUntil.map { Self.isoString(from: $0) },
          metadata.consecutiveErrorCount,
        ]
      )
    }
  }

  private func publicationScopes(
    authorDid: String,
    viewerDid: String?
  ) async throws -> [AppViewPublicationScope] {
    try await db.read { db in
      var sql = """
        SELECT viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris, publication_site_urls, scope_keys,
               section_keys, updated_at
        FROM appview_publication_scopes
        WHERE author_did = ?
        """
      var args: [DatabaseValueConvertible?] = [authorDid]
      if let viewerDid {
        sql += " AND viewer_did = ?"
        args.append(viewerDid)
      }
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
      return rows.compactMap(Self.publicationScope(from:))
    }
  }

  private func readBoundaries(
    viewerDid: String,
    publicationIds: [String]
  ) async throws -> [String: ReadWatermarkBoundary] {
    let uniqueIds = Array(Set(publicationIds)).sorted()
    guard !uniqueIds.isEmpty else { return [:] }
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT publication_id, read_floor_at, read_floor_uri
          FROM appview_publication_read_floors
          WHERE viewer_did = ?
            AND publication_id IN (\(uniqueIds.map { _ in "?" }.joined(separator: ", ")))
          """,
        arguments: StatementArguments([viewerDid] + uniqueIds)
      )
      var boundaries: [String: ReadWatermarkBoundary] = [:]
      for row in rows {
        let publicationId: String = row["publication_id"]
        if let floor = Self.date(fromIso: row["read_floor_at"]) {
          boundaries[publicationId] = ReadWatermarkBoundary(
            publicationId: publicationId,
            createdAt: floor,
            entryId: row["read_floor_uri"]
          )
        }
      }
      return boundaries
    }
  }

  private func countUnreadEntriesAfterBoundary(
    viewerDid: String,
    scope: PublicationUnreadScope,
    readBoundary: ReadWatermarkBoundary
  ) async throws -> Int {
    let nowIso = Self.isoString(from: Date())
    let floorIso = Self.isoString(from: readBoundary.createdAt)
    let uriFloor = readBoundary.entryId
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
      return try await db.read { db in
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*)
            FROM content_items ci
            LEFT JOIN read_marks rm
              ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
            LEFT JOIN appview_unread_overrides uo
              ON uo.viewer_did = ? AND uo.subject_uri = ci.uri
            WHERE ci.author_did = ?
              AND ci.expires_at > ?
              AND (
                ci.created_at > ?
                OR (? IS NOT NULL AND ci.created_at = ? AND ci.uri > ?)
                OR uo.subject_uri IS NOT NULL
              )
              AND ci.publication_site IN (\(siteKeys.map { _ in "?" }.joined(separator: ", ")))
              AND rm.subject_uri IS NULL
            """,
          arguments: StatementArguments(
            [viewerDid, viewerDid, scope.authorDid, nowIso, floorIso, uriFloor, floorIso, uriFloor]
              + siteKeys
          )
        ) ?? 0
      }
    }

    let siteFields: [String?] = try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ci.publication_site
          FROM content_items ci
          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          LEFT JOIN appview_unread_overrides uo
            ON uo.viewer_did = ? AND uo.subject_uri = ci.uri
          WHERE ci.author_did = ?
            AND ci.expires_at > ?
            AND (
              ci.created_at > ?
              OR (? IS NOT NULL AND ci.created_at = ? AND ci.uri > ?)
              OR uo.subject_uri IS NOT NULL
            )
            AND rm.subject_uri IS NULL
          """,
        arguments: [
          viewerDid, viewerDid, scope.authorDid, nowIso,
          floorIso, uriFloor, floorIso, uriFloor,
        ]
      )
      return rows.map { $0["publication_site"] as String? }
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

  private func contentCounterFields(
    uri: String
  ) async throws -> (authorDid: String, publicationSite: String?, createdAt: Date)? {
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT author_did, publication_site, created_at
          FROM content_items
          WHERE uri = ?
          LIMIT 1
          """,
        arguments: [uri]
      ) else {
        return nil
      }
      return (
        authorDid: row["author_did"],
        publicationSite: row["publication_site"] as String?,
        createdAt: Self.date(fromIso: row["created_at"]) ?? Date.distantPast
      )
    }
  }

  private static func publicationScope(from row: Row) -> AppViewPublicationScope? {
    guard
      let updatedAt = date(fromIso: row["updated_at"]),
      let publicationScopeAtUris = try? stringArray(fromJSON: row["publication_scope_at_uris"]),
      let publicationSiteUrls = try? stringArray(fromJSON: row["publication_site_urls"]),
      let scopeKeys = try? stringArray(fromJSON: row["scope_keys"]),
      let sectionKeys = try? stringArray(fromJSON: row["section_keys"])
    else { return nil }
    return AppViewPublicationScope(
      viewerDid: row["viewer_did"],
      publicationId: row["publication_id"],
      authorDid: row["author_did"],
      publicationAtUri: row["publication_at_uri"] as String?,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      scopeKeys: scopeKeys,
      sectionKeys: sectionKeys,
      updatedAt: updatedAt
    )
  }

  private static func unreadCounter(from row: Row) -> AppViewUnreadCounter? {
    guard
      let countedAt = date(fromIso: row["counted_at"]),
      let accuracy = AppViewUnreadCounterAccuracy(rawValue: row["accuracy"])
    else { return nil }
    return AppViewUnreadCounter(
      publicationId: row["publication_id"],
      unreadCount: row["unread_count"],
      generation: Int64(row["generation"] as Int),
      accuracy: accuracy,
      dirty: (row["dirty"] as Int) != 0,
      countedAt: countedAt
    )
  }

  private static func upsertUnreadCounter(
    _ counter: AppViewUnreadCounter,
    viewerDid: String,
    countedAtIso: String,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO appview_unread_counters
          (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
          unread_count = excluded.unread_count,
          generation = excluded.generation,
          accuracy = excluded.accuracy,
          dirty = excluded.dirty,
          counted_at = excluded.counted_at
        """,
      arguments: [
        viewerDid,
        counter.publicationId,
        counter.unreadCount,
        counter.generation,
        counter.accuracy.rawValue,
        counter.dirty ? 1 : 0,
        countedAtIso,
      ]
    )
  }

  private static func adjustUnreadCounter(
    viewerDid: String,
    publicationId: String,
    delta: Int,
    generation: Int64,
    countedAtIso: String,
    db: Database
  ) throws {
    let current = try Int.fetchOne(
      db,
      sql: """
        SELECT unread_count
        FROM appview_unread_counters
        WHERE viewer_did = ? AND publication_id = ?
        LIMIT 1
        """,
      arguments: [viewerDid, publicationId]
    ) ?? 0
    let next = max(0, current + delta)
    try db.execute(
      sql: """
        INSERT INTO appview_unread_counters
          (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
        VALUES (?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
          unread_count = excluded.unread_count,
          generation = excluded.generation,
          accuracy = excluded.accuracy,
          dirty = 1,
          counted_at = excluded.counted_at
        """,
      arguments: [
        viewerDid,
        publicationId,
        next,
        generation,
        AppViewUnreadCounterAccuracy.estimated.rawValue,
        countedAtIso,
      ]
    )
  }

  private static func markUnreadCounterDirty(
    viewerDid: String,
    publicationId: String,
    generation: Int64,
    countedAtIso: String,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO appview_unread_counters
          (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
        VALUES (?, ?, 0, ?, ?, 1, ?)
        ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
          generation = excluded.generation,
          accuracy = excluded.accuracy,
          dirty = 1,
          counted_at = excluded.counted_at
        """,
      arguments: [
        viewerDid,
        publicationId,
        generation,
        AppViewUnreadCounterAccuracy.estimated.rawValue,
        countedAtIso,
      ]
    )
  }

  private static func readBoundary(
    viewerDid: String,
    publicationId: String,
    db: Database
  ) throws -> ReadWatermarkBoundary? {
    guard let row = try Row.fetchOne(
      db,
      sql: """
        SELECT read_floor_at, read_floor_uri
        FROM appview_publication_read_floors
        WHERE viewer_did = ? AND publication_id = ?
        LIMIT 1
        """,
      arguments: [viewerDid, publicationId]
    ) else {
      return nil
    }
    guard let createdAt = date(fromIso: row["read_floor_at"]) else { return nil }
    return ReadWatermarkBoundary(
      publicationId: publicationId,
      createdAt: createdAt,
      entryId: row["read_floor_uri"]
    )
  }

  private static func readBoundaries(
    viewerDid: String,
    publicationIds: [String],
    db: Database
  ) throws -> [String: ReadWatermarkBoundary] {
    let uniqueIds = Array(Set(publicationIds)).sorted()
    guard !uniqueIds.isEmpty else { return [:] }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT publication_id, read_floor_at, read_floor_uri
        FROM appview_publication_read_floors
        WHERE viewer_did = ?
          AND publication_id IN (\(uniqueIds.map { _ in "?" }.joined(separator: ", ")))
        """,
      arguments: StatementArguments([viewerDid] + uniqueIds)
    )
    return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
      let publicationId: String = row["publication_id"]
      guard let createdAt = date(fromIso: row["read_floor_at"]) else { return nil }
      return (
        publicationId,
        ReadWatermarkBoundary(
          publicationId: publicationId,
          createdAt: createdAt,
          entryId: row["read_floor_uri"]
        )
      )
    })
  }

  private static func hasUnreadOverride(
    viewerDid: String,
    subjectUri: String,
    db: Database
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT 1 FROM appview_unread_overrides
        WHERE viewer_did = ? AND subject_uri = ?
        LIMIT 1
        """,
      arguments: [viewerDid, subjectUri]
    ) != nil
  }

  private static func newestBoundary(
    scope: PublicationUnreadScope,
    fallback: Date,
    db: Database
  ) throws -> ReadWatermarkBoundary {
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
    if scoped, siteKeys.isEmpty {
      return ReadWatermarkBoundary(
        publicationId: scope.publicationId,
        createdAt: fallback,
        entryId: nil
      )
    }
    let siteClause = scoped
      ? " AND publication_site IN (\(siteKeys.map { _ in "?" }.joined(separator: ", ")))"
      : ""
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT uri, created_at
        FROM content_items
        WHERE author_did = ? AND created_at <= ?
          \(siteClause)
        ORDER BY created_at DESC, uri DESC
        LIMIT 1
        """,
      arguments: StatementArguments(
        [scope.authorDid, isoString(from: fallback)] + siteKeys
      )
    )
    if let row = rows.first {
      let uri: String = row["uri"]
      let createdAt = date(fromIso: row["created_at"]) ?? fallback
      return ReadWatermarkBoundary(
        publicationId: scope.publicationId,
        createdAt: createdAt,
        entryId: uri
      )
    }
    return ReadWatermarkBoundary(
      publicationId: scope.publicationId,
      createdAt: fallback,
      entryId: nil
    )
  }

  private static func deleteCoveredUnreadOverrides(
    viewerDid: String,
    scope: PublicationUnreadScope,
    boundary: ReadWatermarkBoundary,
    createdBeforeOrAt: String,
    db: Database
  ) throws {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT uo.subject_uri, ci.created_at, ci.publication_site
        FROM appview_unread_overrides uo
        INNER JOIN content_items ci ON ci.uri = uo.subject_uri
        WHERE uo.viewer_did = ?
          AND uo.created_at <= ?
          AND ci.author_did = ?
        """,
      arguments: [viewerDid, createdBeforeOrAt, scope.authorDid]
    )
    let covered = rows.compactMap { row -> String? in
      let subjectUri: String = row["subject_uri"]
      let createdAt = date(fromIso: row["created_at"]) ?? .distantFuture
      let publicationSite: String? = row["publication_site"]
      guard boundary.contains(createdAt: createdAt, entryId: subjectUri) else { return nil }
      guard ThinAppViewQuerySupport.publicationSiteMatches(
        siteField: publicationSite,
        publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls
      ) else {
        return nil
      }
      return subjectUri
    }
    guard !covered.isEmpty else { return }
    try db.execute(
      sql: """
        DELETE FROM appview_unread_overrides
        WHERE viewer_did = ?
          AND subject_uri IN (\(covered.map { _ in "?" }.joined(separator: ", ")))
        """,
      arguments: StatementArguments([viewerDid] + covered)
    )
  }

  private static func writeViewerFeedProjection(
    scopes: [AppViewPublicationScope],
    feeds: [AppViewViewerFeed],
    memberships: [AppViewFeedPublication],
    db: Database
  ) throws {
    for scope in scopes {
      try db.execute(
        sql: """
          INSERT INTO appview_publication_scopes
            (viewer_did, publication_id, author_did, publication_at_uri,
             publication_scope_at_uris, publication_site_urls, scope_keys,
             section_keys, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
            author_did = excluded.author_did,
            publication_at_uri = excluded.publication_at_uri,
            publication_scope_at_uris = excluded.publication_scope_at_uris,
            publication_site_urls = excluded.publication_site_urls,
            scope_keys = excluded.scope_keys,
            section_keys = excluded.section_keys,
            updated_at = excluded.updated_at
          """,
        arguments: [
          scope.viewerDid,
          scope.publicationId,
          scope.authorDid,
          scope.publicationAtUri,
          try jsonString(scope.publicationScopeAtUris),
          try jsonString(scope.publicationSiteUrls),
          try jsonString(scope.scopeKeys),
          try jsonString(scope.sectionKeys),
          isoString(from: scope.updatedAt),
        ]
      )
    }
    for feed in feeds where feed.kind != .publication {
      try db.execute(
        sql: """
          INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id, updated_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (viewer_did, feed_kind, feed_id)
          DO UPDATE SET updated_at = excluded.updated_at
          """,
        arguments: [
          feed.viewerDid,
          feed.kind.rawValue,
          feed.feedId,
          isoString(from: feed.updatedAt),
        ]
      )
    }
    for membership in memberships where membership.kind != .publication {
      try db.execute(
        sql: """
          INSERT INTO appview_feed_publications
            (viewer_did, feed_kind, feed_id, publication_id)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (viewer_did, feed_kind, feed_id, publication_id) DO NOTHING
          """,
        arguments: [
          membership.viewerDid,
          membership.kind.rawValue,
          membership.feedId,
          membership.publicationId,
        ]
      )
    }
  }

  private func updateFailedInboxLease(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    status: String,
    failureCategory: String,
    failureReason: String,
    nextAttemptAt: Date,
    expiresAt: Date?,
    at: Date
  ) async throws {
    try await db.write { db in
      try Self.updateFailedInboxLease(
        db: db,
        environment: environment,
        sourceGeneration: sourceGeneration,
        sequence: sequence,
        workerId: workerId,
        leaseToken: leaseToken,
        status: status,
        failureCategory: failureCategory,
        failureReason: failureReason,
        nextAttemptAt: nextAttemptAt,
        expiresAt: expiresAt,
        at: at
      )
    }
  }

  private static func updateFailedInboxLease(
    db: Database,
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    status: String,
    failureCategory: String,
    failureReason: String,
    nextAttemptAt: Date,
    expiresAt: Date?,
    at: Date
  ) throws {
    let now = isoString(from: at)
    try db.execute(
      sql: """
        UPDATE appview_ingestion_inbox
        SET status = ?, attempt_count = attempt_count + 1,
            next_attempt_at = ?, lease_owner = NULL, lease_token = NULL,
            lease_expires_at = NULL, failure_category = ?, failure_reason = ?,
            dead_lettered_at = CASE WHEN ? = 'dead_letter' THEN ? ELSE dead_lettered_at END,
            expires_at = COALESCE(?, expires_at), updated_at = ?
        WHERE environment = ? AND source_generation = ? AND seq = ?
          AND status = 'leased' AND lease_owner = ? AND lease_token = ?
        """,
      arguments: [
        status,
        isoString(from: nextAttemptAt),
        failureCategory,
        String(failureReason.prefix(1_000)),
        status,
        now,
        expiresAt.map(isoString(from:)),
        now,
        environment,
        sourceGeneration,
        sequence,
        workerId,
        leaseToken,
      ]
    )
    guard db.changesCount == 1 else { throw AppViewIngestionInboxStoreError.staleLease }
  }

  private static func advanceAppliedInboxWatermark(
    db: Database,
    environment: String,
    sourceGeneration: String,
    at: Date
  ) throws {
    let barrier: Int64? = try Int64.fetchOne(
      db,
      sql: """
        SELECT MIN(seq)
        FROM appview_ingestion_inbox
        WHERE environment = ? AND source_generation = ?
          AND status NOT IN ('applied', 'filtered_scope') AND reconciled_at IS NULL
        """,
      arguments: [environment, sourceGeneration]
    )
    let candidate: Int64?
    if let barrier {
      candidate = try Int64.fetchOne(
        db,
        sql: """
          SELECT MAX(seq)
          FROM appview_ingestion_inbox
          WHERE environment = ? AND source_generation = ? AND seq < ?
            AND (status IN ('applied', 'filtered_scope') OR reconciled_at IS NOT NULL)
          """,
        arguments: [environment, sourceGeneration, barrier]
      )
    } else {
      candidate = try Int64.fetchOne(
        db,
        sql: """
          SELECT last_staged_seq
          FROM appview_jetstream_checkpoints
          WHERE environment = ? AND source_generation = ?
          """,
        arguments: [environment, sourceGeneration]
      )
    }
    guard let candidate else { return }
    let candidateEventTime: String? = try String.fetchOne(
      db,
      sql: """
        SELECT COALESCE(
          (SELECT event_time FROM appview_ingestion_inbox
           WHERE environment = ? AND source_generation = ? AND seq = ?),
          (SELECT last_staged_event_at FROM appview_jetstream_checkpoints
           WHERE environment = ? AND source_generation = ?)
        )
        """,
      arguments: [
        environment, sourceGeneration, candidate, environment, sourceGeneration,
      ]
    )
    let now = isoString(from: at)
    try db.execute(
      sql: """
        UPDATE appview_jetstream_checkpoints
        SET last_applied_seq = ?, last_applied_event_at = ?, last_applied_at = ?, updated_at = ?
        WHERE environment = ? AND source_generation = ?
          AND (last_applied_seq IS NULL OR last_applied_seq < ?)
        """,
      arguments: [
        candidate,
        candidateEventTime,
        now,
        now,
        environment,
        sourceGeneration,
        candidate,
      ]
    )
  }

  private static func jsonString(_ values: [String]) throws -> String {
    let data = try JSONEncoder().encode(values)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return string
  }

  private static func stringArray(fromJSON raw: String) throws -> [String] {
    guard let data = raw.data(using: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return try JSONDecoder().decode([String].self, from: data)
  }

  private static func tapStateArguments(_ state: TapRepositorySyncState) -> StatementArguments {
    [
      state.environment,
      state.repoDid,
      state.repoRev,
      state.accountStatus.rawValue,
      state.pdsBase,
      state.lastEventId,
      state.lastEventLive ? 1 : 0,
      state.parityStatus.rawValue,
      state.matchedEventCount,
      state.mismatchedEventCount,
      state.lastMismatch,
      state.lastIndexedAt.map(isoString(from:)),
      state.lastValidatedAt.map(isoString(from:)),
      isoString(from: state.updatedAt),
    ]
  }

  private static func isoString(from date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func date(fromIso raw: String) -> Date? {
    ISO8601DateFormatter().date(from: raw)
  }
}
