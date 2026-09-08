import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWireDependencyRecoveryStore: Sendable {
  static let snapshotGeneration = "wire-pds-hydration-v1"
  let pool: PostgresClient
  let logger: Logger
  let environment: String

  struct SeedCursor: Sendable {
    let time: Date
    let generation: String
    let sequence: Int64
  }

  func seed(after cursor: SeedCursor?, asOf: Date) async throws -> SeedCursor? {
    var query = PostgresQuery.StringInterpolation(literalCapacity: 1000, interpolationCount: 8)
    query.appendLiteral("""
      WITH page AS MATERIALIZED (
        SELECT environment, source_generation, seq, event_time, source_uri, record_cid, subject_uri
        FROM wire_recommendation_journal WHERE status = 'pending' AND environment =
      """)
    query.appendInterpolation(environment)
    query.appendLiteral(" AND event_time > ")
    query.appendInterpolation(asOf.addingTimeInterval(-WireDataPolicy.signalRetention))
    if let cursor {
      query.appendLiteral(" AND (event_time, source_generation, seq) > (")
      query.appendInterpolation(cursor.time); query.appendLiteral(", ")
      query.appendInterpolation(cursor.generation); query.appendLiteral(", ")
      query.appendInterpolation(cursor.sequence); query.appendLiteral(")")
    }
    query.appendLiteral("""
        ORDER BY event_time, source_generation, seq LIMIT 256
      ), seeded AS (
        INSERT INTO wire_recommendation_dependency_recovery
          (environment, source_uri, source_generation, seq, expected_cid, subject_uri,
           next_attempt_at, updated_at)
        SELECT page.environment, page.source_uri, page.source_generation, page.seq,
               page.record_cid, page.subject_uri,
      """)
    query.appendInterpolation(asOf); query.appendLiteral(", "); query.appendInterpolation(asOf)
    query.appendLiteral("""
        FROM page JOIN wire_recommendation_record_fences fence
          ON fence.environment = page.environment AND fence.source_uri = page.source_uri
         AND fence.source_generation = page.source_generation AND fence.seq = page.seq
        ON CONFLICT (environment, source_uri) DO UPDATE SET
          source_generation = EXCLUDED.source_generation, seq = EXCLUDED.seq,
          expected_cid = EXCLUDED.expected_cid, subject_uri = EXCLUDED.subject_uri,
          status = 'pending', next_attempt_at = EXCLUDED.next_attempt_at,
          lease_token = NULL, lease_expires_at = NULL, verification_token = NULL,
          staged_document_seq = NULL, staged_publication_seq = NULL,
          attempt_count = 0, updated_at = EXCLUDED.updated_at
        WHERE (wire_recommendation_dependency_recovery.source_generation,
               wire_recommendation_dependency_recovery.seq)
          IS DISTINCT FROM (EXCLUDED.source_generation, EXCLUDED.seq)
        RETURNING source_uri
      )
      SELECT event_time, source_generation, seq FROM page
      ORDER BY event_time DESC, source_generation DESC, seq DESC LIMIT 1
      """)
    for try await row in try await pool.query(PostgresQuery(stringInterpolation: query), logger: logger) {
      let value = try row.decode((Date, String, Int64).self)
      return SeedCursor(time: value.0, generation: value.1, sequence: value.2)
    }
    return nil
  }

  func claim(asOf: Date, limit: Int) async throws -> [WireRecommendationHydrationJob] {
    let token = UUID().uuidString.lowercased()
    let rows = try await pool.query(
      """
      WITH candidates AS MATERIALIZED (
        SELECT recovery.source_uri, recovery.source_generation, recovery.seq
        FROM wire_recommendation_dependency_recovery recovery
        WHERE environment = \(environment) AND next_attempt_at <= \(asOf)
        ORDER BY next_attempt_at, source_uri LIMIT \(max(1, min(16, limit)))
        FOR UPDATE SKIP LOCKED
      ), current_candidates AS (
        SELECT candidates.*, COALESCE(journal.status = 'pending' AND journal.event_time > \(asOf.addingTimeInterval(-WireDataPolicy.signalRetention)) AND fence.seq IS NOT NULL, FALSE) AS is_current
        FROM candidates
        LEFT JOIN wire_recommendation_journal journal ON journal.environment = \(environment)
          AND journal.source_generation = candidates.source_generation AND journal.seq = candidates.seq
        LEFT JOIN wire_recommendation_record_fences fence ON fence.environment = \(environment)
          AND fence.source_uri = candidates.source_uri AND fence.source_generation = candidates.source_generation
          AND fence.seq = candidates.seq
      ), claimed AS (
        UPDATE wire_recommendation_dependency_recovery recovery
        SET status = CASE WHEN candidates.is_current THEN 'leased' ELSE 'superseded' END,
            lease_token = CASE WHEN candidates.is_current THEN \(token) ELSE NULL END,
            lease_expires_at = CASE WHEN candidates.is_current THEN \(asOf.addingTimeInterval(180)) ELSE NULL END,
            next_attempt_at = CASE WHEN candidates.is_current THEN \(asOf.addingTimeInterval(180)) ELSE \(Date.distantFuture) END,
            attempt_count = attempt_count + 1, updated_at = \(asOf)
        FROM current_candidates candidates WHERE recovery.environment = \(environment)
          AND recovery.source_uri = candidates.source_uri
        RETURNING recovery.*
      )
      SELECT claimed.environment, claimed.source_uri, claimed.source_generation, claimed.seq,
             claimed.expected_cid, claimed.subject_uri, journal.repo_did, journal.repo_rev,
             journal.event_time, claimed.lease_token, claimed.attempt_count
      FROM claimed JOIN wire_recommendation_journal journal
        ON journal.environment = claimed.environment AND journal.source_generation = claimed.source_generation
       AND journal.seq = claimed.seq
      WHERE claimed.status = 'leased'
      """, logger: logger)
    var jobs: [WireRecommendationHydrationJob] = []
    for try await row in rows {
      let v = try row.decode((String, String, String, Int64, String?, String?, String, String?, Date, String, Int).self)
      jobs.append(.init(environment: v.0, sourceURI: v.1, generation: v.2, sequence: v.3,
        expectedCID: v.4, subjectURI: v.5, repoDID: v.6, originalRevision: v.7,
        originalTime: v.8, token: v.9, attempts: v.10))
    }
    return jobs
  }

  func hasAlias(_ uri: String, asOf: Date) async throws -> Bool {
    for try await row in try await pool.query(
      "SELECT EXISTS(SELECT 1 FROM wire_item_aliases WHERE alias_key = \(uri) AND expires_at > \(asOf))", logger: logger)
    { return try row.decode(Bool.self) }
    return false
  }

  /// All network work has completed before taking these row/account/source locks.
  func observe(
    _ job: WireRecommendationHydrationJob, status: String, cid: String?, subject: String?,
    revision: String?, observedAt: Date?, reason: String?, asOf: Date
  ) async throws -> Bool {
    try await pool.withTransaction(logger: logger) { connection in
      guard try await current(job, on: connection, asOf: asOf, requireLease: true) else { return false }
      let validUntil = status == "verified" ? (observedAt ?? asOf).addingTimeInterval(300) : nil
      let next = ["absent", "changed", "superseded", "unsupported"].contains(status)
        ? Date.distantFuture : validUntil ?? asOf.addingTimeInterval(job.retryDelay)
      try Task.checkCancellation()
      try await connection.query(
        """
        UPDATE wire_recommendation_dependency_recovery
        SET status = \(status), verified_cid = \(cid), verified_subject_uri = \(subject),
            observed_repo_rev = \(revision), observed_at = \(observedAt), valid_until = \(validUntil),
            verification_token = \(status == "verified" ? job.token : nil),
            staged_document_seq = NULL, staged_publication_seq = NULL,
            next_attempt_at = \(next), lease_token = NULL, lease_expires_at = NULL,
            failure_reason = \(reason), updated_at = \(asOf)
        WHERE environment = \(job.environment) AND source_uri = \(job.sourceURI)
        """, logger: logger)
      return true
    }
  }

  func postpone(_ job: WireRecommendationHydrationJob, reason: String, asOf: Date) async throws {
    try await pool.query(
      """
      UPDATE wire_recommendation_dependency_recovery
      SET status = 'unavailable', next_attempt_at = \(asOf.addingTimeInterval(job.retryDelay)),
          lease_token = NULL, lease_expires_at = NULL, failure_reason = \(reason), updated_at = \(asOf)
      WHERE environment = \(job.environment) AND source_uri = \(job.sourceURI)
        AND ((status = 'leased' AND lease_token = \(job.token) AND lease_expires_at > \(asOf))
          OR (status = 'verified' AND verification_token = \(job.token) AND valid_until > \(asOf)))
        AND source_generation = \(job.generation) AND seq = \(job.sequence)
      """, logger: logger)
  }

  func stage(
    _ records: [WireVerifiedPublicRecord], for job: WireRecommendationHydrationJob, asOf: Date
  ) async throws -> [WireInboxEvent] {
    try await pool.withTransaction(logger: logger) { connection in
      guard try await current(job, on: connection, asOf: asOf, requireLease: false) else { return [] }
      let existing = try await connection.query(
        """
        SELECT staged_document_seq FROM wire_recommendation_dependency_recovery
        WHERE environment = \(job.environment) AND source_uri = \(job.sourceURI)
        """, logger: logger)
      for try await row in existing where try row.decode(Int64?.self) != nil { return [] }
      var events: [WireInboxEvent] = []
      for record in records {
        guard ["site.standard.document", "site.standard.entry", "site.standard.publication"].contains(record.collection),
          let value = try JSONSerialization.jsonObject(with: record.recordJSON) as? [String: Any]
        else { throw RecoveryError.invalidRecord }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
          "snapshot": ["record": value, "cid": record.cid, "rev": record.repositoryRevision] as [String: Any]
        ]), as: UTF8.self)
        var sequence: Int64?
        for try await row in try await connection.query("SELECT nextval('wire_pds_hydration_sequence')", logger: logger) {
          sequence = try row.decode(Int64.self)
        }
        guard let sequence else { throw RecoveryError.invalidRecord }
        try Task.checkCancellation()
        try await connection.query(
          """
          INSERT INTO wire_ingestion_inbox
            (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
             collection, operation, record_key, record_cid, repo_rev, payload, event_time,
             status, lease_owner, lease_token, lease_expires_at, next_attempt_at, attempt_count)
          VALUES (\(environment), \(Self.snapshotGeneration), \(sequence), \(record.pdsBase),
                  'pds_record_snapshot', 'snapshot', \(record.repoDID), \(record.collection), 'update',
                  \(record.recordKey), \(record.cid), \(record.repositoryRevision), \(payload)::jsonb,
                  \(record.observedAt), 'leased', 'wire-dependency-recovery', \(job.token),
                  \(asOf.addingTimeInterval(120)), \(asOf), 1)
          """, logger: logger)
        events.append(.init(environment: environment, sourceGeneration: Self.snapshotGeneration,
          sequence: sequence, sourceHost: record.pdsBase, cursorKind: "pds_record_snapshot", eventKind: "snapshot",
          repoDID: record.repoDID, collection: record.collection, operation: "update", recordKey: record.recordKey,
          payloadJSON: payload, eventTime: record.observedAt, leaseToken: job.token, attemptCount: 1))
      }
      if !events.isEmpty {
        try await connection.query(
          """
          INSERT INTO wire_ingestion_admission (environment, retained_rows, updated_at)
          VALUES (\(environment), \(Int64(events.count)), \(asOf))
          ON CONFLICT (environment) DO UPDATE
          SET retained_rows = wire_ingestion_admission.retained_rows + EXCLUDED.retained_rows,
              updated_at = EXCLUDED.updated_at
          """, logger: logger)
      }
      let documentSequence = events.last(where: { $0.collection != "site.standard.publication" })?.sequence
      let publicationSequence = events.first(where: { $0.collection == "site.standard.publication" })?.sequence
      try await connection.query(
        """
        UPDATE wire_recommendation_dependency_recovery
        SET staged_document_seq = \(documentSequence), staged_publication_seq = \(publicationSequence), updated_at = \(asOf)
        WHERE environment = \(job.environment) AND source_uri = \(job.sourceURI)
        """, logger: logger)
      return events
    }
  }

  /// Proof validity is shorter than the dependency backoff. Wake the exact
  /// original only after its real subject alias is available, under the same fences.
  func wake(_ job: WireRecommendationHydrationJob, asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      guard try await current(job, on: connection, asOf: asOf, requireLease: false) else { return }
      try Task.checkCancellation()
      try await connection.query(
        """
        UPDATE wire_recommendation_journal SET next_attempt_at = \(asOf), updated_at = \(asOf)
        WHERE environment = \(job.environment) AND source_generation = \(job.generation)
          AND seq = \(job.sequence) AND status = 'pending' AND next_attempt_at > \(asOf)
        """, logger: logger)
    }
  }

  private func current(
    _ job: WireRecommendationHydrationJob, on connection: PostgresConnection, asOf: Date, requireLease: Bool
  ) async throws -> Bool {
    let accountLock = "wire-recommendation-account:\(job.environment):\(job.repoDID)"
    try await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(\(accountLock), 0))", logger: logger)
    try await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(\(job.sourceURI), 0))", logger: logger)
    let rows = try await connection.query(
      """
      SELECT TRUE FROM wire_recommendation_dependency_recovery recovery
      JOIN wire_recommendation_record_fences fence ON fence.environment = recovery.environment
        AND fence.source_uri = recovery.source_uri AND fence.source_generation = recovery.source_generation
        AND fence.seq = recovery.seq
      JOIN wire_recommendation_journal journal ON journal.environment = recovery.environment
        AND journal.source_generation = recovery.source_generation AND journal.seq = recovery.seq
      WHERE recovery.environment = \(job.environment) AND recovery.source_uri = \(job.sourceURI)
        AND recovery.source_generation = \(job.generation) AND recovery.seq = \(job.sequence)
        AND journal.status = 'pending'
        AND ((\(requireLease) AND recovery.status = 'leased' AND recovery.lease_token = \(job.token)
              AND recovery.lease_expires_at > \(asOf))
          OR (NOT \(requireLease) AND recovery.status = 'verified' AND recovery.verification_token = \(job.token)
              AND recovery.valid_until > \(asOf)))
        AND NOT EXISTS (SELECT 1 FROM wire_recommendation_account_fences account
          WHERE account.environment = recovery.environment AND account.repo_did = journal.repo_did
            AND (NOT account.active OR journal.event_time <= account.inactive_through))
      FOR UPDATE OF recovery
      """, logger: logger)
    for try await _ in rows { return true }
    return false
  }

  private enum RecoveryError: Error { case invalidRecord }
}
