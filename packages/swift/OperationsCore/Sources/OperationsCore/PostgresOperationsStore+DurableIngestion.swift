import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  public func fetchIngestionDurabilitySnapshot(
    at: Date = Date()
  ) async throws -> IngestionDurabilitySnapshot {
    let checkpointRows = try await pool.query(
      """
      SELECT checkpoint.environment, checkpoint.source_generation, checkpoint.source_host,
        checkpoint.stream_nsid, checkpoint.filter_fingerprint, checkpoint.cursor_kind,
        checkpoint.last_staged_seq, checkpoint.last_staged_event_at, checkpoint.last_staged_at,
        checkpoint.last_applied_seq, checkpoint.last_applied_event_at, checkpoint.last_applied_at,
        checkpoint.last_reconciled_repo_rev, checkpoint.last_reconciled_at,
        checkpoint.replay_state, checkpoint.replay_after_seq, checkpoint.replay_sealed_seq,
        checkpoint.replay_bytes_downloaded, checkpoint.replay_retry_count,
        checkpoint.replay_range_resume_count, checkpoint.replay_last_progress_at,
        checkpoint.updated_at,
        (SELECT MAX(lease.updated_at)
         FROM appview_ingestion_leases lease
         WHERE lease.environment = checkpoint.environment
           AND lease.source_generation = checkpoint.source_generation
           AND lease.released_at IS NULL AND lease.lease_expires_at >= \(at))
          AS intake_heartbeat_at
      FROM appview_jetstream_checkpoints checkpoint
      WHERE checkpoint.environment = \(environment)
      ORDER BY checkpoint.updated_at DESC, checkpoint.source_generation
      """, logger: logger)
    var checkpoints: [JetstreamDurabilityCheckpoint] = []
    for try await row in checkpointRows {
      checkpoints.append(try Self.durabilityCheckpoint(row))
    }

    let inboxRows = try await pool.query(
      """
      SELECT
        COUNT(*) FILTER (WHERE status = 'pending')::bigint,
        COUNT(*) FILTER (WHERE status = 'leased')::bigint,
        COUNT(*) FILTER (WHERE status = 'retry')::bigint,
        COUNT(*) FILTER (WHERE status = 'applied')::bigint,
        COUNT(*) FILTER (WHERE status = 'dead_letter' AND reconciled_at IS NULL)::bigint,
        COUNT(*)::bigint,
        MIN(staged_at) FILTER (WHERE status IN ('pending', 'leased', 'retry'))
      FROM appview_ingestion_inbox
      WHERE environment = \(environment)
      """, logger: logger)
    var inbox = IngestionInboxMetrics()
    for try await row in inboxRows {
      let value = try row.decode((Int64, Int64, Int64, Int64, Int64, Int64, Date?).self)
      inbox = IngestionInboxMetrics(
        pending: Int(value.0), leased: Int(value.1), retrying: Int(value.2),
        applied: Int(value.3), deadLetters: Int(value.4), total: Int(value.5),
        oldestPendingAt: value.6,
        oldestPendingAgeSeconds: value.6.map { max(0, at.timeIntervalSince($0)) })
      break
    }
    let generationInboxRows = try await pool.query(
      """
      SELECT source_generation,
        COUNT(*) FILTER (WHERE status = 'pending')::bigint,
        COUNT(*) FILTER (WHERE status = 'leased')::bigint,
        COUNT(*) FILTER (WHERE status = 'retry')::bigint,
        COUNT(*) FILTER (WHERE status = 'applied')::bigint,
        COUNT(*) FILTER (WHERE status = 'dead_letter' AND reconciled_at IS NULL)::bigint,
        COUNT(*)::bigint,
        MIN(staged_at) FILTER (WHERE status IN ('pending', 'leased', 'retry'))
      FROM appview_ingestion_inbox
      WHERE environment = \(environment)
      GROUP BY source_generation
      """,
      logger: logger
    )
    var inboxBySourceGeneration: [String: IngestionInboxMetrics] = [:]
    for try await row in generationInboxRows {
      let value = try row.decode(
        (String, Int64, Int64, Int64, Int64, Int64, Int64, Date?).self
      )
      inboxBySourceGeneration[value.0] = IngestionInboxMetrics(
        pending: Int(value.1), leased: Int(value.2), retrying: Int(value.3),
        applied: Int(value.4), deadLetters: Int(value.5), total: Int(value.6),
        oldestPendingAt: value.7,
        oldestPendingAgeSeconds: value.7.map { max(0, at.timeIntervalSince($0)) }
      )
    }

    let incidentRows = try await pool.query(
      """
      SELECT
        COUNT(*) FILTER (WHERE status = 'open')::bigint,
        COUNT(*) FILTER (WHERE status = 'recovering')::bigint,
        COUNT(*) FILTER (WHERE status = 'verification_required')::bigint,
        COUNT(*) FILTER (WHERE status = 'resolved')::bigint,
        COUNT(*) FILTER (WHERE status = 'ignored')::bigint,
        MAX(last_detected_at)
      FROM appview_ingestion_incidents
      WHERE environment = \(environment)
      """, logger: logger)
    var incidents = IngestionIncidentMetrics()
    for try await row in incidentRows {
      let value = try row.decode((Int64, Int64, Int64, Int64, Int64, Date?).self)
      incidents = IngestionIncidentMetrics(
        open: Int(value.0), recovering: Int(value.1), verificationRequired: Int(value.2),
        resolved: Int(value.3), ignored: Int(value.4), latestDetectedAt: value.5)
      break
    }
    let usageRows = try await pool.query(
      """
      SELECT COALESCE(SUM(bytes_downloaded), 0)::bigint
      FROM appview_ingestion_replay_usage
      WHERE environment = \(environment) AND bucket_started_at > \(at.addingTimeInterval(-86_400))
      """, logger: logger)
    var replayBytesRolling24Hours: Int64 = 0
    for try await row in usageRows {
      replayBytesRolling24Hours = try row.decode(Int64.self)
      break
    }
    return IngestionDurabilitySnapshot(
      environment: environment, checkpoints: checkpoints, inbox: inbox,
      inboxBySourceGeneration: inboxBySourceGeneration,
      incidents: incidents, replayBytesRolling24Hours: replayBytesRolling24Hours,
      generatedAt: at)
  }

  public func listIngestionIncidents(
    limit: Int,
    before: String?
  ) async throws -> OperationsPage<IngestionIncident> {
    let boundedLimit = max(1, min(limit, 250))
    let cursor = before.flatMap(OperationsPaginationCursor.decode)
    if before != nil && cursor == nil { throw OperationsStoreError.invalidPaginationCursor }
    let beforeDate = cursor?.date
    let beforeID = cursor?.id
    let rows = try await pool.query(
      """
      SELECT environment, id, source_generation, source_host, source, cursor_kind, start_cursor,
        end_cursor, category, status, occurrence_count, first_detected_at, last_detected_at,
        last_error, replay_state, replay_bytes_downloaded, replay_retry_count,
        replay_range_resume_count, replay_sealed_seq, recovered_through_cursor,
        verification_evidence::text, resolved_at, updated_at, version
      FROM appview_ingestion_incidents
      WHERE environment = \(environment)
        AND (\(beforeDate)::timestamptz IS NULL
          OR last_detected_at < \(beforeDate)::timestamptz
          OR (last_detected_at = \(beforeDate)::timestamptz AND id < \(beforeID)::text))
      ORDER BY last_detected_at DESC, id DESC
      LIMIT \(boundedLimit + 1)
      """, logger: logger)
    var decoded: [IngestionIncident] = []
    for try await row in rows { decoded.append(try Self.ingestionIncident(row)) }
    let countRows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM appview_ingestion_incidents WHERE environment = \(environment)",
      logger: logger)
    var total = 0
    for try await row in countRows { total = Int(try row.decode(Int64.self)); break }
    let items = Array(decoded.prefix(boundedLimit))
    let next = decoded.count > boundedLimit
      ? items.last.map {
          OperationsPaginationCursor.encode(date: $0.lastDetectedAt, id: $0.id)
        } : nil
    return OperationsPage(items: items, nextCursor: next, totalCount: total)
  }

  public func upsertOrMergeActiveIncident(
    _ candidate: IngestionIncidentCandidate,
    legacyGapId: String? = nil
  ) async throws -> IngestionIncident {
    try Self.validate(candidate)
    let boundedSource = String(candidate.source.prefix(128))
    let boundedHost = candidate.sourceHost.map { String($0.prefix(512)) }
    let boundedCategory = String(candidate.category.prefix(128))
    let boundedError = candidate.error.map { String($0.prefix(512)) }
    let lower = candidate.startCursor ?? candidate.endCursor
    let upper = candidate.endCursor ?? candidate.startCursor
    return try await pool.withTransaction(logger: logger) { connection in
      _ = try await connection.query(
        """
        SELECT pg_advisory_xact_lock(hashtextextended(
          \(environment) || '|' || \(boundedSource) || '|' ||
          COALESCE(\(candidate.sourceGeneration), '') || '|' || COALESCE(\(boundedHost), '') || '|' ||
          \(candidate.cursorKind.rawValue) || '|' || \(boundedCategory), 0))
        """, logger: logger)
      let matchingRows = try await connection.query(
        """
        SELECT environment, id, source_generation, source_host, source, cursor_kind, start_cursor,
          end_cursor, category, status, occurrence_count, first_detected_at, last_detected_at,
          last_error, replay_state, replay_bytes_downloaded, replay_retry_count,
          replay_range_resume_count, replay_sealed_seq, recovered_through_cursor,
          verification_evidence::text, resolved_at, updated_at, version
        FROM appview_ingestion_incidents
        WHERE environment = \(environment)
          AND source = \(boundedSource)
          AND source_generation IS NOT DISTINCT FROM \(candidate.sourceGeneration)
          AND source_host IS NOT DISTINCT FROM \(boundedHost)
          AND cursor_kind = \(candidate.cursorKind.rawValue)
          AND category = \(boundedCategory)
          AND status IN ('open', 'recovering', 'verification_required')
        ORDER BY first_detected_at, id
        FOR UPDATE
        """, logger: logger)
      var matching: [IngestionIncident] = []
      for try await row in matchingRows { matching.append(try Self.ingestionIncident(row)) }

      let incident: IngestionIncident
      if let target = matching.first {
        let startCursor = ([lower] + matching.map(\.startCursor)).compactMap { $0 }.min()
        let endCursor = ([upper] + matching.map(\.endCursor)).compactMap { $0 }.max()
        let occurrences = matching.reduce(Int64(1)) { $0 + $1.occurrenceCount }
        let firstDetectedAt = ([candidate.detectedAt] + matching.map(\.firstDetectedAt)).min()
          ?? candidate.detectedAt
        let lastDetectedAt = ([candidate.detectedAt] + matching.map(\.lastDetectedAt)).max()
          ?? candidate.detectedAt
        let updatedRows = try await connection.query(
          """
          UPDATE appview_ingestion_incidents
          SET start_cursor = \(startCursor), end_cursor = \(endCursor),
            occurrence_count = \(occurrences), first_detected_at = \(firstDetectedAt),
            last_detected_at = \(lastDetectedAt),
            last_error = COALESCE(\(boundedError), last_error), updated_at = \(candidate.detectedAt),
            version = version + 1
          WHERE environment = \(environment) AND id = \(target.id)
          RETURNING environment, id, source_generation, source_host, source, cursor_kind, start_cursor,
            end_cursor, category, status, occurrence_count, first_detected_at, last_detected_at,
            last_error, replay_state, replay_bytes_downloaded, replay_retry_count,
            replay_range_resume_count, replay_sealed_seq, recovered_through_cursor,
            verification_evidence::text, resolved_at, updated_at, version
          """, logger: logger)
        var updated: IngestionIncident?
        for try await row in updatedRows { updated = try Self.ingestionIncident(row); break }
        guard let updated else { throw OperationsStoreError.missingCreatedRecord }
        incident = updated

        for duplicate in matching.dropFirst() {
          try await connection.query(
            """
            INSERT INTO appview_ingestion_incident_gaps
              (environment, incident_id, gap_id, linked_at)
            SELECT environment, \(target.id), gap_id, \(candidate.detectedAt)
            FROM appview_ingestion_incident_gaps
            WHERE environment = \(environment) AND incident_id = \(duplicate.id)
            ON CONFLICT DO NOTHING
            """, logger: logger)
          try await connection.query(
            """
            UPDATE appview_ingestion_incidents
            SET status = 'ignored', resolved_at = \(candidate.detectedAt),
              verification_evidence = verification_evidence
                || jsonb_build_object('mergedInto', \(target.id)),
              updated_at = \(candidate.detectedAt), version = version + 1
            WHERE environment = \(environment) AND id = \(duplicate.id)
            """, logger: logger)
        }
      } else {
        let id = UUID().uuidString.lowercased()
        let insertedRows = try await connection.query(
          """
          INSERT INTO appview_ingestion_incidents
            (environment, id, source_generation, source_host, source, cursor_kind, start_cursor, end_cursor,
             category, status, occurrence_count, first_detected_at, last_detected_at, last_error,
             updated_at, version)
          VALUES (\(environment), \(id), \(candidate.sourceGeneration), \(boundedHost), \(boundedSource),
            \(candidate.cursorKind.rawValue), \(lower), \(upper), \(boundedCategory), 'open', 1,
            \(candidate.detectedAt), \(candidate.detectedAt), \(boundedError),
            \(candidate.detectedAt), 0)
          RETURNING environment, id, source_generation, source_host, source, cursor_kind, start_cursor,
            end_cursor, category, status, occurrence_count, first_detected_at, last_detected_at,
            last_error, replay_state, replay_bytes_downloaded, replay_retry_count,
            replay_range_resume_count, replay_sealed_seq, recovered_through_cursor,
            verification_evidence::text, resolved_at, updated_at, version
          """, logger: logger)
        var inserted: IngestionIncident?
        for try await row in insertedRows { inserted = try Self.ingestionIncident(row); break }
        guard let inserted else { throw OperationsStoreError.missingCreatedRecord }
        incident = inserted
      }

      if let legacyGapId {
        try await connection.query(
          """
          INSERT INTO appview_ingestion_incident_gaps
            (environment, incident_id, gap_id, linked_at)
          SELECT \(environment), \(incident.id), id, \(candidate.detectedAt)
          FROM appview_ingestion_gaps
          WHERE environment = \(environment) AND id = \(legacyGapId)
          ON CONFLICT DO NOTHING
          """, logger: logger)
      }
      return incident
    }
  }

  public func acquireIngestionLeaderLease(
    name: String,
    sourceGeneration: String,
    ownerID: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> IngestionLeaderLease? {
    guard leaseUntil > at else { throw OperationsStoreError.invalidProgress }
    let rows = try await pool.query(
      """
      INSERT INTO appview_ingestion_leases
        (environment, lease_name, source_generation, owner_id, fencing_token, acquired_at,
         lease_expires_at, released_at, updated_at)
      VALUES (\(environment), \(String(name.prefix(128))), \(sourceGeneration), \(ownerID), 1,
        \(at), \(leaseUntil), NULL, \(at))
      ON CONFLICT (environment, lease_name) DO UPDATE SET
        source_generation = EXCLUDED.source_generation,
        owner_id = EXCLUDED.owner_id,
        fencing_token = CASE
          WHEN appview_ingestion_leases.owner_id = EXCLUDED.owner_id
            AND appview_ingestion_leases.source_generation = EXCLUDED.source_generation
            AND appview_ingestion_leases.released_at IS NULL
            AND appview_ingestion_leases.lease_expires_at > \(at)
          THEN appview_ingestion_leases.fencing_token
          ELSE appview_ingestion_leases.fencing_token + 1 END,
        acquired_at = CASE
          WHEN appview_ingestion_leases.owner_id = EXCLUDED.owner_id
            AND appview_ingestion_leases.source_generation = EXCLUDED.source_generation
            AND appview_ingestion_leases.released_at IS NULL
            AND appview_ingestion_leases.lease_expires_at > \(at)
          THEN appview_ingestion_leases.acquired_at ELSE EXCLUDED.acquired_at END,
        lease_expires_at = EXCLUDED.lease_expires_at, released_at = NULL,
        updated_at = EXCLUDED.updated_at
      WHERE appview_ingestion_leases.released_at IS NOT NULL
        OR appview_ingestion_leases.lease_expires_at <= \(at)
        OR (appview_ingestion_leases.owner_id = EXCLUDED.owner_id
          AND appview_ingestion_leases.source_generation = EXCLUDED.source_generation)
      RETURNING environment, lease_name, source_generation, owner_id, fencing_token,
        acquired_at, lease_expires_at, updated_at
      """, logger: logger)
    for try await row in rows { return try Self.ingestionLeaderLease(row) }
    return nil
  }

  public func renewIngestionLeaderLease(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    leaseUntil: Date,
    at: Date
  ) async throws -> IngestionLeaderLease {
    guard leaseUntil > at else { throw OperationsStoreError.invalidProgress }
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_leases
      SET lease_expires_at = \(leaseUntil), updated_at = \(at)
      WHERE environment = \(environment) AND lease_name = \(String(name.prefix(128)))
        AND owner_id = \(ownerID) AND fencing_token = \(fencingToken)
        AND released_at IS NULL AND lease_expires_at >= \(at)
      RETURNING environment, lease_name, source_generation, owner_id, fencing_token,
        acquired_at, lease_expires_at, updated_at
      """, logger: logger)
    for try await row in rows { return try Self.ingestionLeaderLease(row) }
    throw OperationsStoreError.leaseConflict
  }

  public func releaseIngestionLeaderLease(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_leases
      SET released_at = \(at), updated_at = \(at)
      WHERE environment = \(environment) AND lease_name = \(String(name.prefix(128)))
        AND owner_id = \(ownerID) AND fencing_token = \(fencingToken)
        AND released_at IS NULL
      RETURNING fencing_token
      """, logger: logger)
    for try await _ in rows { return }
    throw OperationsStoreError.leaseConflict
  }

  public func withIngestionLeaderLeaseFence(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        SELECT fencing_token
        FROM appview_ingestion_leases
        WHERE environment = \(environment) AND lease_name = \(String(name.prefix(128)))
          AND owner_id = \(ownerID) AND fencing_token = \(fencingToken)
          AND released_at IS NULL AND lease_expires_at >= \(at)
        FOR UPDATE
        """,
        logger: logger
      )
      var valid = false
      for try await _ in rows { valid = true }
      guard valid else { throw OperationsStoreError.leaseConflict }
      try await operation()
    }
  }

  private static func durabilityCheckpoint(_ row: PostgresRow) throws
    -> JetstreamDurabilityCheckpoint
  {
    let value = row.makeRandomAccess()
    return JetstreamDurabilityCheckpoint(
      environment: try value["environment"].decode(String.self),
      sourceGeneration: try value["source_generation"].decode(String.self),
      sourceHost: try value["source_host"].decode(String.self),
      streamNSID: try value["stream_nsid"].decode(String.self),
      filterFingerprint: try value["filter_fingerprint"].decode(String.self),
      cursorKind: IngestionCursorKind(
        rawValue: try value["cursor_kind"].decode(String.self)) ?? .unknown,
      lastStagedSequence: try value["last_staged_seq"].decode(Int64?.self),
      lastStagedEventAt: try value["last_staged_event_at"].decode(Date?.self),
      lastStagedAt: try value["last_staged_at"].decode(Date?.self),
      lastAppliedSequence: try value["last_applied_seq"].decode(Int64?.self),
      lastAppliedEventAt: try value["last_applied_event_at"].decode(Date?.self),
      lastAppliedAt: try value["last_applied_at"].decode(Date?.self),
      lastReconciledRepositoryRevision: try value["last_reconciled_repo_rev"].decode(String?.self),
      lastReconciledAt: try value["last_reconciled_at"].decode(Date?.self),
      replayState: JetstreamReplayState(
        rawValue: try value["replay_state"].decode(String.self)) ?? .failed,
      replayAfterSequence: try value["replay_after_seq"].decode(Int64?.self),
      replaySealedSequence: try value["replay_sealed_seq"].decode(Int64?.self),
      replayBytesDownloaded: try value["replay_bytes_downloaded"].decode(Int64.self),
      replayRetryCount: try value["replay_retry_count"].decode(Int.self),
      replayRangeResumeCount: try value["replay_range_resume_count"].decode(Int.self),
      replayLastProgressAt: try value["replay_last_progress_at"].decode(Date?.self),
      intakeHeartbeatAt: try value["intake_heartbeat_at"].decode(Date?.self),
      updatedAt: try value["updated_at"].decode(Date.self))
  }

  private static func ingestionIncident(_ row: PostgresRow) throws -> IngestionIncident {
    let value = row.makeRandomAccess()
    let evidence = try value["verification_evidence"].decode(String.self)
    return IngestionIncident(
      id: try value["id"].decode(String.self),
      environment: try value["environment"].decode(String.self),
      sourceGeneration: try value["source_generation"].decode(String?.self),
      sourceHost: try value["source_host"].decode(String?.self),
      source: try value["source"].decode(String.self),
      cursorKind: IngestionCursorKind(
        rawValue: try value["cursor_kind"].decode(String.self)) ?? .unknown,
      startCursor: try value["start_cursor"].decode(Int64?.self),
      endCursor: try value["end_cursor"].decode(Int64?.self),
      category: try value["category"].decode(String.self),
      status: IngestionIncidentStatus(
        rawValue: try value["status"].decode(String.self)) ?? .open,
      occurrenceCount: try value["occurrence_count"].decode(Int64.self),
      firstDetectedAt: try value["first_detected_at"].decode(Date.self),
      lastDetectedAt: try value["last_detected_at"].decode(Date.self),
      lastError: try value["last_error"].decode(String?.self),
      replayState: try value["replay_state"].decode(String?.self)
        .flatMap(JetstreamReplayState.init(rawValue:)),
      replayBytesDownloaded: try value["replay_bytes_downloaded"].decode(Int64.self),
      replayRetryCount: try value["replay_retry_count"].decode(Int.self),
      replayRangeResumeCount: try value["replay_range_resume_count"].decode(Int.self),
      replaySealedSequence: try value["replay_sealed_seq"].decode(Int64?.self),
      recoveredThroughCursor: try value["recovered_through_cursor"].decode(Int64?.self),
      verificationEvidence: (try? JSONDecoder().decode(
        [String: OperationsJSONScalar].self, from: Data(evidence.utf8))) ?? [:],
      resolvedAt: try value["resolved_at"].decode(Date?.self),
      updatedAt: try value["updated_at"].decode(Date.self),
      version: try value["version"].decode(Int.self))
  }

  private static func ingestionLeaderLease(_ row: PostgresRow) throws -> IngestionLeaderLease {
    let value = row.makeRandomAccess()
    return IngestionLeaderLease(
      environment: try value["environment"].decode(String.self),
      name: try value["lease_name"].decode(String.self),
      sourceGeneration: try value["source_generation"].decode(String.self),
      ownerID: try value["owner_id"].decode(String.self),
      fencingToken: try value["fencing_token"].decode(Int64.self),
      acquiredAt: try value["acquired_at"].decode(Date.self),
      expiresAt: try value["lease_expires_at"].decode(Date.self),
      updatedAt: try value["updated_at"].decode(Date.self))
  }

  private static func validate(_ candidate: IngestionIncidentCandidate) throws {
    if candidate.source.isEmpty || candidate.category.isEmpty { throw OperationsStoreError.invalidProgress }
    if let start = candidate.startCursor, start < 0 { throw OperationsStoreError.invalidProgress }
    if let end = candidate.endCursor, end < 0 { throw OperationsStoreError.invalidProgress }
    if let start = candidate.startCursor, let end = candidate.endCursor, start > end {
      throw OperationsStoreError.invalidProgress
    }
  }
}
