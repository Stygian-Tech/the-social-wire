import Foundation
@preconcurrency import GRDB

extension SQLiteOperationsStore {
  public func fetchIngestionDurabilitySnapshot(
    at: Date = Date()
  ) async throws -> IngestionDurabilitySnapshot {
    try await db.read { database in
      let checkpoints = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM appview_jetstream_checkpoints
          WHERE environment = ? ORDER BY updated_at DESC, source_generation
          """, arguments: [environment]
      ).compactMap(Self.durabilityCheckpoint)
      let inboxRow = try Row.fetchOne(
        database,
        sql: """
          SELECT
            SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending_count,
            SUM(CASE WHEN status = 'leased' THEN 1 ELSE 0 END) AS leased_count,
            SUM(CASE WHEN status = 'retry' THEN 1 ELSE 0 END) AS retry_count,
            SUM(CASE WHEN status = 'applied' THEN 1 ELSE 0 END) AS applied_count,
            SUM(CASE WHEN status = 'dead_letter' AND reconciled_at IS NULL THEN 1 ELSE 0 END)
              AS dead_letter_count,
            COUNT(*) AS total_count,
            MIN(CASE WHEN status IN ('pending', 'leased', 'retry') THEN staged_at END)
              AS oldest_pending_at
          FROM appview_ingestion_inbox WHERE environment = ?
          """, arguments: [environment])
      let oldest = Self.date(inboxRow?["oldest_pending_at"])
      let inbox = IngestionInboxMetrics(
        pending: inboxRow?["pending_count"] ?? 0,
        leased: inboxRow?["leased_count"] ?? 0,
        retrying: inboxRow?["retry_count"] ?? 0,
        applied: inboxRow?["applied_count"] ?? 0,
        deadLetters: inboxRow?["dead_letter_count"] ?? 0,
        total: inboxRow?["total_count"] ?? 0,
        oldestPendingAt: oldest,
        oldestPendingAgeSeconds: oldest.map { max(0, at.timeIntervalSince($0)) })
      let incidentRow = try Row.fetchOne(
        database,
        sql: """
          SELECT
            SUM(CASE WHEN status = 'open' THEN 1 ELSE 0 END) AS open_count,
            SUM(CASE WHEN status = 'recovering' THEN 1 ELSE 0 END) AS recovering_count,
            SUM(CASE WHEN status = 'verification_required' THEN 1 ELSE 0 END)
              AS verification_count,
            SUM(CASE WHEN status = 'resolved' THEN 1 ELSE 0 END) AS resolved_count,
            SUM(CASE WHEN status = 'ignored' THEN 1 ELSE 0 END) AS ignored_count,
            MAX(last_detected_at) AS latest_detected_at
          FROM appview_ingestion_incidents WHERE environment = ?
          """, arguments: [environment])
      let incidents = IngestionIncidentMetrics(
        open: incidentRow?["open_count"] ?? 0,
        recovering: incidentRow?["recovering_count"] ?? 0,
        verificationRequired: incidentRow?["verification_count"] ?? 0,
        resolved: incidentRow?["resolved_count"] ?? 0,
        ignored: incidentRow?["ignored_count"] ?? 0,
        latestDetectedAt: Self.date(incidentRow?["latest_detected_at"]))
      let replayBytesRolling24Hours = try Int64.fetchOne(
        database,
        sql: """
          SELECT COALESCE(SUM(bytes_downloaded), 0)
          FROM appview_ingestion_replay_usage
          WHERE environment = ? AND bucket_started_at > ?
          """, arguments: [environment, Self.iso(at.addingTimeInterval(-86_400))]) ?? 0
      return IngestionDurabilitySnapshot(
        environment: environment, checkpoints: checkpoints, inbox: inbox,
        incidents: incidents, replayBytesRolling24Hours: replayBytesRolling24Hours,
        generatedAt: at)
    }
  }

  public func listIngestionIncidents(
    limit: Int,
    before: String?
  ) async throws -> OperationsPage<IngestionIncident> {
    let boundedLimit = max(1, min(limit, 250))
    let cursor = before.flatMap(OperationsPaginationCursor.decode)
    if before != nil && cursor == nil { throw OperationsStoreError.invalidPaginationCursor }
    return try await db.read { database in
      var arguments: StatementArguments = [environment]
      var cursorPredicate = ""
      if let cursor {
        let date = Self.iso(cursor.date)
        cursorPredicate = " AND (last_detected_at < ? OR (last_detected_at = ? AND id < ?))"
        arguments += [date, date, cursor.id]
      }
      arguments += [boundedLimit + 1]
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM appview_ingestion_incidents
          WHERE environment = ?\(cursorPredicate)
          ORDER BY last_detected_at DESC, id DESC LIMIT ?
          """, arguments: arguments
      ).compactMap(Self.ingestionIncident)
      let total = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_ingestion_incidents WHERE environment = ?",
        arguments: [environment]) ?? 0
      let items = Array(rows.prefix(boundedLimit))
      let next = rows.count > boundedLimit
        ? items.last.map {
            OperationsPaginationCursor.encode(date: $0.lastDetectedAt, id: $0.id)
          } : nil
      return OperationsPage(items: items, nextCursor: next, totalCount: total)
    }
  }

  public func upsertOrMergeActiveIncident(
    _ candidate: IngestionIncidentCandidate,
    legacyGapId: String? = nil
  ) async throws -> IngestionIncident {
    try Self.validate(candidate)
    let source = String(candidate.source.prefix(128))
    let sourceHost = candidate.sourceHost.map { String($0.prefix(512)) }
    let category = String(candidate.category.prefix(128))
    let error = candidate.error.map { String($0.prefix(512)) }
    let lower = candidate.startCursor ?? candidate.endCursor
    let upper = candidate.endCursor ?? candidate.startCursor
    return try await db.write { database in
      let matches = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM appview_ingestion_incidents
          WHERE environment = ? AND source = ?
            AND ((source_generation IS NULL AND ? IS NULL) OR source_generation = ?)
            AND ((source_host IS NULL AND ? IS NULL) OR source_host = ?)
            AND cursor_kind = ? AND category = ?
            AND status IN ('open', 'recovering', 'verification_required')
          ORDER BY first_detected_at, id
          """,
        arguments: [
          environment, source, candidate.sourceGeneration, candidate.sourceGeneration,
          sourceHost, sourceHost,
          candidate.cursorKind.rawValue, category,
        ]
      ).compactMap(Self.ingestionIncident)

      let incident: IngestionIncident
      if let target = matches.first {
        let start = ([lower] + matches.map(\.startCursor)).compactMap { $0 }.min()
        let end = ([upper] + matches.map(\.endCursor)).compactMap { $0 }.max()
        let occurrenceCount = matches.reduce(Int64(1)) { $0 + $1.occurrenceCount }
        let firstAt = ([candidate.detectedAt] + matches.map(\.firstDetectedAt)).min()
          ?? candidate.detectedAt
        let lastAt = ([candidate.detectedAt] + matches.map(\.lastDetectedAt)).max()
          ?? candidate.detectedAt
        try database.execute(
          sql: """
            UPDATE appview_ingestion_incidents
            SET start_cursor = ?, end_cursor = ?, occurrence_count = ?,
              first_detected_at = ?, last_detected_at = ?,
              last_error = COALESCE(?, last_error), updated_at = ?, version = version + 1
            WHERE environment = ? AND id = ?
            """,
          arguments: [
            start, end, occurrenceCount, Self.iso(firstAt), Self.iso(lastAt), error,
            Self.iso(candidate.detectedAt), environment, target.id,
          ])
        for duplicate in matches.dropFirst() {
          try database.execute(
            sql: """
              INSERT OR IGNORE INTO appview_ingestion_incident_gaps
                (environment, incident_id, gap_id, linked_at)
              SELECT environment, ?, gap_id, ? FROM appview_ingestion_incident_gaps
              WHERE environment = ? AND incident_id = ?
              """,
            arguments: [target.id, Self.iso(candidate.detectedAt), environment, duplicate.id])
          let evidenceData = try JSONEncoder().encode(["mergedInto": target.id])
          let evidence = String(decoding: evidenceData, as: UTF8.self)
          try database.execute(
            sql: """
              UPDATE appview_ingestion_incidents
              SET status = 'ignored', resolved_at = ?, verification_evidence = ?,
                updated_at = ?, version = version + 1
              WHERE environment = ? AND id = ?
              """,
            arguments: [
              Self.iso(candidate.detectedAt), evidence, Self.iso(candidate.detectedAt),
              environment, duplicate.id,
            ])
        }
        guard let row = try Row.fetchOne(
          database,
          sql: "SELECT * FROM appview_ingestion_incidents WHERE environment = ? AND id = ?",
          arguments: [environment, target.id]),
          let updated = Self.ingestionIncident(row)
        else { throw OperationsStoreError.missingCreatedRecord }
        incident = updated
      } else {
        let id = UUID().uuidString.lowercased()
        try database.execute(
          sql: """
            INSERT INTO appview_ingestion_incidents
              (environment, id, source_generation, source_host, source, cursor_kind, start_cursor, end_cursor,
               category, status, occurrence_count, first_detected_at, last_detected_at,
               last_error, updated_at, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', 1, ?, ?, ?, ?, 0)
            """,
          arguments: [
            environment, id, candidate.sourceGeneration, sourceHost, source, candidate.cursorKind.rawValue,
            lower, upper, category, Self.iso(candidate.detectedAt),
            Self.iso(candidate.detectedAt), error, Self.iso(candidate.detectedAt),
          ])
        guard let row = try Row.fetchOne(
          database,
          sql: "SELECT * FROM appview_ingestion_incidents WHERE environment = ? AND id = ?",
          arguments: [environment, id]),
          let inserted = Self.ingestionIncident(row)
        else { throw OperationsStoreError.missingCreatedRecord }
        incident = inserted
      }
      if let legacyGapId {
        try database.execute(
          sql: """
            INSERT OR IGNORE INTO appview_ingestion_incident_gaps
              (environment, incident_id, gap_id, linked_at)
            SELECT ?, ?, id, ? FROM appview_ingestion_gaps
            WHERE environment = ? AND id = ?
            """,
          arguments: [
            environment, incident.id, Self.iso(candidate.detectedAt), environment, legacyGapId,
          ])
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
    if let fence = ingestionLeaderFenceCounts[String(name.prefix(128))],
      fence.ownerID != ownerID
    {
      return nil
    }
    return try await db.write { database in
      let boundedName = String(name.prefix(128))
      let existing = try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_ingestion_leases WHERE environment = ? AND lease_name = ?",
        arguments: [environment, boundedName])
      let existingExpiry = Self.date(existing?["lease_expires_at"])
      let existingReleased: String? = existing?["released_at"]
      let existingOwner: String? = existing?["owner_id"]
      let existingGeneration: String? = existing?["source_generation"]
      if existing != nil, existingReleased == nil, let existingExpiry, existingExpiry > at,
        (existingOwner != ownerID || existingGeneration != sourceGeneration)
      {
        return nil
      }
      let sameLease = existing != nil && existingReleased == nil && existingExpiry.map { $0 > at } == true
        && existingOwner == ownerID && existingGeneration == sourceGeneration
      let existingToken: Int64 = existing?["fencing_token"] ?? 0
      let token = sameLease ? existingToken : existingToken + 1
      let acquiredAt: String = sameLease ? (existing?["acquired_at"] ?? Self.iso(at)) : Self.iso(at)
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_leases
            (environment, lease_name, source_generation, owner_id, fencing_token, acquired_at,
             lease_expires_at, released_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
          ON CONFLICT (environment, lease_name) DO UPDATE SET
            source_generation = excluded.source_generation, owner_id = excluded.owner_id,
            fencing_token = excluded.fencing_token, acquired_at = excluded.acquired_at,
            lease_expires_at = excluded.lease_expires_at, released_at = NULL,
            updated_at = excluded.updated_at
          """,
        arguments: [
          environment, boundedName, sourceGeneration, ownerID, token, acquiredAt,
          Self.iso(leaseUntil), Self.iso(at),
        ])
      guard let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_ingestion_leases WHERE environment = ? AND lease_name = ?",
        arguments: [environment, boundedName]),
        let lease = Self.ingestionLeaderLease(row)
      else { throw OperationsStoreError.missingCreatedRecord }
      return lease
    }
  }

  public func renewIngestionLeaderLease(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    leaseUntil: Date,
    at: Date
  ) async throws -> IngestionLeaderLease {
    guard leaseUntil > at else { throw OperationsStoreError.invalidProgress }
    return try await db.write { database in
      let boundedName = String(name.prefix(128))
      try database.execute(
        sql: """
          UPDATE appview_ingestion_leases SET lease_expires_at = ?, updated_at = ?
          WHERE environment = ? AND lease_name = ? AND owner_id = ? AND fencing_token = ?
            AND released_at IS NULL AND lease_expires_at >= ?
          """,
        arguments: [
          Self.iso(leaseUntil), Self.iso(at), environment, boundedName, ownerID, fencingToken,
          Self.iso(at),
        ])
      guard database.changesCount == 1,
        let row = try Row.fetchOne(
          database,
          sql: "SELECT * FROM appview_ingestion_leases WHERE environment = ? AND lease_name = ?",
          arguments: [environment, boundedName]),
        let lease = Self.ingestionLeaderLease(row)
      else { throw OperationsStoreError.leaseConflict }
      return lease
    }
  }

  public func releaseIngestionLeaderLease(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date
  ) async throws {
    if let fence = ingestionLeaderFenceCounts[String(name.prefix(128))],
      fence.ownerID == ownerID, fence.fencingToken == fencingToken
    {
      throw OperationsStoreError.leaseConflict
    }
    try await db.write { database in
      try database.execute(
        sql: """
          UPDATE appview_ingestion_leases SET released_at = ?, updated_at = ?
          WHERE environment = ? AND lease_name = ? AND owner_id = ? AND fencing_token = ?
            AND released_at IS NULL
          """,
        arguments: [
          Self.iso(at), Self.iso(at), environment, String(name.prefix(128)), ownerID, fencingToken,
        ])
      guard database.changesCount == 1 else { throw OperationsStoreError.leaseConflict }
    }
  }

  public func withIngestionLeaderLeaseFence(
    name: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    let boundedName = String(name.prefix(128))
    let valid = try await db.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM appview_ingestion_leases
            WHERE environment = ? AND lease_name = ? AND owner_id = ? AND fencing_token = ?
              AND released_at IS NULL AND lease_expires_at >= ?)
          """,
        arguments: [environment, boundedName, ownerID, fencingToken, Self.iso(at)]
      ) ?? false
    }
    guard valid else { throw OperationsStoreError.leaseConflict }
    if let existing = ingestionLeaderFenceCounts[boundedName] {
      guard existing.ownerID == ownerID, existing.fencingToken == fencingToken else {
        throw OperationsStoreError.leaseConflict
      }
      ingestionLeaderFenceCounts[boundedName] = IngestionLeaderFenceState(
        ownerID: ownerID, fencingToken: fencingToken, count: existing.count + 1)
    } else {
      ingestionLeaderFenceCounts[boundedName] = IngestionLeaderFenceState(
        ownerID: ownerID, fencingToken: fencingToken, count: 1)
    }
    defer {
      if let existing = ingestionLeaderFenceCounts[boundedName] {
        if existing.count == 1 {
          ingestionLeaderFenceCounts.removeValue(forKey: boundedName)
        } else {
          ingestionLeaderFenceCounts[boundedName] = IngestionLeaderFenceState(
            ownerID: existing.ownerID,
            fencingToken: existing.fencingToken,
            count: existing.count - 1)
        }
      }
    }
    try await operation()
  }

  private static func durabilityCheckpoint(_ row: Row) -> JetstreamDurabilityCheckpoint? {
    guard let updatedAt = date(row["updated_at"]) else { return nil }
    return JetstreamDurabilityCheckpoint(
      environment: row["environment"], sourceGeneration: row["source_generation"],
      sourceHost: row["source_host"], streamNSID: row["stream_nsid"],
      filterFingerprint: row["filter_fingerprint"],
      cursorKind: IngestionCursorKind(rawValue: row["cursor_kind"]) ?? .unknown,
      lastStagedSequence: row["last_staged_seq"],
      lastStagedEventAt: date(row["last_staged_event_at"]),
      lastStagedAt: date(row["last_staged_at"]),
      lastAppliedSequence: row["last_applied_seq"],
      lastAppliedEventAt: date(row["last_applied_event_at"]),
      lastAppliedAt: date(row["last_applied_at"]),
      lastReconciledRepositoryRevision: row["last_reconciled_repo_rev"],
      lastReconciledAt: date(row["last_reconciled_at"]),
      replayState: JetstreamReplayState(rawValue: row["replay_state"]) ?? .failed,
      replayAfterSequence: row["replay_after_seq"],
      replaySealedSequence: row["replay_sealed_seq"],
      replayBytesDownloaded: row["replay_bytes_downloaded"],
      replayRetryCount: row["replay_retry_count"],
      replayRangeResumeCount: row["replay_range_resume_count"],
      replayLastProgressAt: date(row["replay_last_progress_at"]), updatedAt: updatedAt)
  }

  private static func ingestionIncident(_ row: Row) -> IngestionIncident? {
    guard let first = date(row["first_detected_at"]),
      let last = date(row["last_detected_at"]),
      let updated = date(row["updated_at"])
    else { return nil }
    let evidenceJSON: String = row["verification_evidence"]
    return IngestionIncident(
      id: row["id"], environment: row["environment"],
      sourceGeneration: row["source_generation"], sourceHost: row["source_host"],
      source: row["source"],
      cursorKind: IngestionCursorKind(rawValue: row["cursor_kind"]) ?? .unknown,
      startCursor: row["start_cursor"], endCursor: row["end_cursor"],
      category: row["category"],
      status: IngestionIncidentStatus(rawValue: row["status"]) ?? .open,
      occurrenceCount: row["occurrence_count"], firstDetectedAt: first,
      lastDetectedAt: last, lastError: row["last_error"],
      replayState: (row["replay_state"] as String?).flatMap(JetstreamReplayState.init(rawValue:)),
      replayBytesDownloaded: row["replay_bytes_downloaded"],
      replayRetryCount: row["replay_retry_count"],
      replayRangeResumeCount: row["replay_range_resume_count"],
      replaySealedSequence: row["replay_sealed_seq"],
      recoveredThroughCursor: row["recovered_through_cursor"],
      verificationEvidence: decode([String: OperationsJSONScalar].self, evidenceJSON) ?? [:],
      resolvedAt: date(row["resolved_at"]), updatedAt: updated, version: row["version"])
  }

  private static func ingestionLeaderLease(_ row: Row) -> IngestionLeaderLease? {
    guard let acquiredAt = date(row["acquired_at"]),
      let expiresAt = date(row["lease_expires_at"]),
      let updatedAt = date(row["updated_at"])
    else { return nil }
    return IngestionLeaderLease(
      environment: row["environment"], name: row["lease_name"],
      sourceGeneration: row["source_generation"], ownerID: row["owner_id"],
      fencingToken: row["fencing_token"], acquiredAt: acquiredAt,
      expiresAt: expiresAt, updatedAt: updatedAt)
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

struct IngestionLeaderFenceState: Sendable {
  let ownerID: String
  let fencingToken: Int64
  let count: Int
}
