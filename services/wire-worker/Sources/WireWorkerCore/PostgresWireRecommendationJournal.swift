import Foundation
import Logging
import PostgresNIO
import WireCore

/// The logged handoff separates a missing recommendation subject from the
/// repository inbox. All recommendation mutations use the same version fence.
struct PostgresWireRecommendationJournal: Sendable {
  let pool: PostgresClient
  let logger: Logger
  private let recoveryCursor = WireRecommendationRecoveryCursor()

  init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  private enum JournalError: Error { case malformedRecommendation }
  private enum Ordering { case newer, same, older, conflict }
  private struct Entry: Sendable {
    let environment: String
    let generation: String
    let sequence: Int64
    let host: String
    let cursor: String
    let repo: String
    let uri: String
    let operation: String
    let revision: String?
    let cid: String?
    let time: Date
    let actor: String
    let subject: String?
    let status: String
    let attempts: Int

    var eventKey: String { "\(environment):\(generation):\(sequence)" }
    var transportKey: String { "transport:\(environment):\(host):\(cursor):\(sequence)" }
  }

  func process(event: WireInboxEvent, actorHasher: WireActorHasher, asOf: Date, deferUnresolved: Bool = true) async throws
    -> WireInboxEventOutcome
  {
    try Task.checkCancellation()
    guard event.collection == "site.standard.graph.recommend",
      let uri = event.sourceURI, let operation = event.operation,
      ["create", "update", "delete"].contains(operation)
    else { throw JournalError.malformedRecommendation }
    let actor = try actorHasher.hash(event.repoDID)
    return try await pool.withTransaction(logger: logger) { connection in
      let leaseRows = try await connection.query(
        """
        SELECT repo_rev, record_cid
        FROM wire_ingestion_inbox
        WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
          AND seq = \(event.sequence) AND status = 'leased' AND lease_token = \(event.leaseToken)
          AND lease_expires_at > \(asOf)
        FOR UPDATE
        """, logger: logger)
      var version: (String?, String?)?
      for try await row in leaseRows { version = try row.decode((String?, String?).self) }
      guard let version else { return .leaseLost }
      try Task.checkCancellation()
      try await lockRecord(event.environment, repo: event.repoDID, uri: uri, on: connection)
      let subject: String?
      if operation == "delete" {
        subject = nil
      } else {
        guard let payload = (try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)))
          as? [String: Any], let commit = payload["commit"] as? [String: Any],
          let record = commit["record"] as? [String: Any],
          let value = PostgresWireInboxProcessor.referenceSubjectURI(
            record: record, collection: event.collection),
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          try await connection.query(
            """
            UPDATE wire_ingestion_inbox
            SET status = 'dead_letter', dead_lettered_at = \(asOf), applied_at = NULL,
                lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
                failure_category = 'malformed_event', failure_reason = 'malformed_event',
                expires_at = \(asOf.addingTimeInterval(7 * 86_400)), updated_at = \(asOf)
            WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
              AND seq = \(event.sequence) AND status = 'leased' AND lease_token = \(event.leaseToken)
            """, logger: logger)
          return .terminal
        }
        subject = value
      }
      try await connection.query(
        """
        INSERT INTO wire_recommendation_journal
          (environment, source_generation, seq, source_host, cursor_kind, repo_did,
           source_uri, operation, repo_rev, record_cid, payload, event_time,
           actor_key_hash, subject_uri, next_attempt_at, created_at, updated_at)
        VALUES (\(event.environment), \(event.sourceGeneration), \(event.sequence),
                \(event.sourceHost), \(event.cursorKind), \(event.repoDID), \(uri),
                \(operation), \(version.0), \(version.1), \(event.payloadJSON)::jsonb,
                \(event.eventTime), \(actor), \(subject), \(asOf), \(asOf), \(asOf))
        ON CONFLICT (environment, source_generation, seq) DO NOTHING
        """, logger: logger)
      guard let entry = try await read(
        environment: event.environment, generation: event.sourceGeneration,
        sequence: event.sequence, on: connection)
      else { throw JournalError.malformedRecommendation }
      let status = try await reconcile(entry, on: connection, asOf: asOf)
      try Task.checkCancellation()
      let inboxStatus: String
      switch status {
      case "resolved", "deleted": inboxStatus = "applied"
      case "superseded", "expired": inboxStatus = "superseded"
      default: inboxStatus = deferUnresolved ? "deferred" : "retry"
      }
      let appliedAt: Date? = inboxStatus == "applied" ? asOf : nil
      let reason: String? = inboxStatus == "applied" ? nil : "recommendation_\(status)"
      let retryAt = inboxStatus == "retry" ? asOf.addingTimeInterval(30) : asOf
      let expiresAt = inboxStatus == "retry" ? Date.distantFuture : asOf.addingTimeInterval(300)
      try await connection.query(
        """
        UPDATE wire_ingestion_inbox
        SET status = \(inboxStatus), applied_at = \(appliedAt), dead_lettered_at = NULL,
            lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
            failure_category = \(reason), failure_reason = \(reason),
            next_attempt_at = \(retryAt), expires_at = \(expiresAt),
            updated_at = \(asOf)
        WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
          AND seq = \(event.sequence) AND status = 'leased' AND lease_token = \(event.leaseToken)
        """, logger: logger)
      switch inboxStatus {
      case "applied": return .applied
      case "deferred": return .deferred
      case "retry": return .retry
      default: return .terminal
      }
    }
  }

  /// Short database-only transactions hold the record lock through mutation;
  /// there is no external network call or lease that can expire mid-apply.
  /// A scope with no generations includes every journal generation in that
  /// environment, including retired intake generations with durable work.
  func recover(asOf: Date, limit: Int, sourceScope: WireInboxSourceScope? = nil) async throws
    -> WireRecommendationRecoveryCounts
  {
    try Task.checkCancellation()
    let boundedLimit = max(1, min(limit, 100))
    // Reserve slots for lost-projection repair instead of making a permanently
    // missing subject starve restart recovery. Both reads have bounded pages.
    var candidates = try await dueCandidates(
      asOf: asOf, limit: max(1, boundedLimit / 2), scope: sourceScope)
    let repairs = try await projectionCandidates(
      asOf: asOf, limit: max(0, boundedLimit - candidates.count), scope: sourceScope)
    candidates.append(contentsOf: repairs)
    var result = WireRecommendationRecoveryCounts()
    for key in candidates {
      try Task.checkCancellation()
      let status: String? = try await pool.withTransaction(logger: logger) { connection in
        guard let entry = try await read(
          environment: key.0, generation: key.1, sequence: key.2, on: connection)
        else { return nil }
        // Match account -> source lock order used by immediate ingestion. Avoid
        // waiting behind another drain and leave its work for a later pass.
        let lockRows = try await connection.query(
          "SELECT pg_try_advisory_xact_lock(hashtextextended(\(Self.accountLockKey(entry.environment, entry.repo)), 0))",
          logger: logger)
        var acquired = false
        for try await row in lockRows { acquired = try row.decode(Bool.self) }
        guard acquired else { return nil }
        try await connection.query(
          "SELECT pg_advisory_xact_lock(hashtextextended(\(entry.uri), 0))", logger: logger)
        guard let current = try await read(
          environment: key.0, generation: key.1, sequence: key.2, on: connection),
          current.status == "pending" || current.status == "resolved"
        else { return nil }
        let readyRows = try await connection.query(
          """
          SELECT EXISTS(SELECT 1 FROM wire_recommendation_journal journal
            WHERE environment = \(key.0) AND source_generation = \(key.1) AND seq = \(key.2)
              AND ((status = 'pending' AND next_attempt_at <= \(asOf))
                OR (status = 'resolved' AND event_time > \(asOf.addingTimeInterval(-WireDataPolicy.signalRetention))
                  AND NOT EXISTS (SELECT 1 FROM wire_signal_events
                    WHERE occurred_at = \(current.time) AND source_uri = journal.source_uri
                      AND transport_event_key = \(current.transportKey)))))
          """, logger: logger)
        var ready = false
        for try await row in readyRows { ready = try row.decode(Bool.self) }
        guard ready else { return nil }
        return try await reconcile(current, on: connection, asOf: asOf)
      }
      guard let status else { continue }
      result.attempted += 1
      switch status {
      case "resolved", "deleted": result.resolved += 1
      case "conflict": result.conflicted += 1
      case "superseded", "expired": result.superseded += 1
      default: result.pending += 1
      }
    }
    return result
  }

  private func dueCandidates(asOf: Date, limit: Int, scope: WireInboxSourceScope?) async throws
    -> [(String, String, Int64)]
  {
    var query = PostgresQuery.StringInterpolation(literalCapacity: 700, interpolationCount: 4)
    query.appendLiteral("SELECT environment, source_generation, seq FROM wire_recommendation_journal WHERE status = 'pending' AND next_attempt_at <= ")
    query.appendInterpolation(asOf)
    Self.appendScope(scope, to: &query)
    query.appendLiteral(" ORDER BY next_attempt_at, environment, source_generation, seq LIMIT ")
    query.appendInterpolation(limit)
    let rows = try await pool.query(PostgresQuery(stringInterpolation: query), logger: logger)
    var result: [(String, String, Int64)] = []
    for try await row in rows { result.append(try row.decode((String, String, Int64).self)) }
    return result
  }

  private func projectionCandidates(asOf: Date, limit: Int, scope: WireInboxSourceScope?) async throws
    -> [(String, String, Int64)]
  {
    guard limit > 0 else { return [] }
    let scopeKey = scope.map { "\($0.environment):\($0.sourceGenerations.sorted().joined(separator: ","))" } ?? "*"
    let position = await recoveryCursor.position(for: scopeKey)
    var query = PostgresQuery.StringInterpolation(literalCapacity: 1_700, interpolationCount: 10)
    query.appendLiteral("""
      WITH page AS MATERIALIZED (
        SELECT environment, source_generation, seq, source_host, cursor_kind, source_uri, event_time
        FROM wire_recommendation_journal WHERE status = 'resolved' AND event_time >
      """)
    query.appendLiteral(" ")
    query.appendInterpolation(asOf.addingTimeInterval(-WireDataPolicy.signalRetention))
    Self.appendScope(scope, to: &query)
    if let position {
      query.appendLiteral(" AND (event_time, environment, source_generation, seq) > (")
      query.appendInterpolation(position.time)
      query.appendLiteral(", ")
      query.appendInterpolation(position.environment)
      query.appendLiteral(", ")
      query.appendInterpolation(position.generation)
      query.appendLiteral(", ")
      query.appendInterpolation(position.sequence)
      query.appendLiteral(")")
    }
    query.appendLiteral("\n")
    query.appendLiteral("""
        ORDER BY event_time, environment, source_generation, seq LIMIT 256
      )
      SELECT page.environment, page.source_generation, page.seq, page.event_time,
             projection.found IS NULL
      FROM page LEFT JOIN LATERAL (
        SELECT TRUE AS found FROM wire_signal_events signal
        WHERE signal.occurred_at = page.event_time AND signal.source_uri = page.source_uri
          AND signal.transport_event_key = 'transport:' || page.environment || ':'
            || page.source_host || ':' || page.cursor_kind || ':' || page.seq::text
        LIMIT 1 OFFSET 0
      ) projection ON TRUE
      ORDER BY page.event_time, page.environment, page.source_generation, page.seq
      """)
    let rows = try await pool.query(PostgresQuery(stringInterpolation: query), logger: logger)
    var result: [(String, String, Int64)] = []
    var last: WireRecommendationRecoveryCursor.Position?
    for try await row in rows {
      let value = try row.decode((String, String, Int64, Date, Bool).self)
      // Do not advance past a missing projection that this pass cannot repair.
      if result.count >= limit { break }
      last = .init(time: value.3, environment: value.0, generation: value.1, sequence: value.2)
      if value.4 { result.append((value.0, value.1, value.2)) }
    }
    // An exhausted sweep wraps on the next poll. Starting again after a process
    // restart is safe because actual signal writes are idempotent.
    await recoveryCursor.advance(last, for: scopeKey)
    return result
  }

  private static func appendScope(_ scope: WireInboxSourceScope?, to query: inout PostgresQuery.StringInterpolation) {
    guard let scope else { return }
    query.appendLiteral(" AND environment = ")
    query.appendInterpolation(scope.environment)
    guard !scope.sourceGenerations.isEmpty else { return }
    query.appendLiteral(" AND source_generation = ANY(")
    query.appendInterpolation(scope.sourceGenerations)
    query.appendLiteral(")")
  }

  /// The caller must perform account retractions on this same connection and
  /// transaction. An inactive cutoff survives a later reactivation.
  static func observeAccount(event: WireInboxEvent, on connection: PostgresConnection, asOf: Date)
    async throws -> Bool
  {
    try Task.checkCancellation()
    guard let document = try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8))
      as? [String: Any], let account = document["account"] as? [String: Any],
      let active = account["active"] as? Bool
    else { return false }
    let logger = Logger(label: "wire-recommendation-account-fence")
    let leaseRows = try await connection.query(
      """
      SELECT TRUE FROM wire_ingestion_inbox
      WHERE environment = \(event.environment) AND source_generation = \(event.sourceGeneration)
        AND seq = \(event.sequence) AND status = 'leased' AND lease_token = \(event.leaseToken)
        AND lease_expires_at > \(asOf)
      FOR UPDATE
      """, logger: logger)
    var validLease = false
    for try await row in leaseRows { validLease = try row.decode(Bool.self) }
    guard validLease else { return false }
    try await connection.query(
      "SELECT pg_advisory_xact_lock(hashtextextended(\(accountLockKey(event.environment, event.repoDID)), 0))",
      logger: logger)
    let rows = try await connection.query(
      """
      INSERT INTO wire_recommendation_account_fences
        (environment, repo_did, active, event_time, inactive_through, updated_at)
      VALUES (\(event.environment), \(event.repoDID), \(active), \(event.eventTime),
              \(active ? nil : event.eventTime), \(asOf))
      ON CONFLICT (environment, repo_did) DO UPDATE SET
        active = CASE WHEN EXCLUDED.event_time > wire_recommendation_account_fences.event_time
                        OR (EXCLUDED.event_time = wire_recommendation_account_fences.event_time AND NOT EXCLUDED.active)
                      THEN EXCLUDED.active ELSE wire_recommendation_account_fences.active END,
        event_time = GREATEST(wire_recommendation_account_fences.event_time, EXCLUDED.event_time),
        inactive_through = GREATEST(wire_recommendation_account_fences.inactive_through,
                                   EXCLUDED.inactive_through), updated_at = EXCLUDED.updated_at
      RETURNING event_time = \(event.eventTime) AND active = \(active)
      """, logger: logger)
    for try await row in rows { return try row.decode(Bool.self) }
    return false
  }

  private static func accountLockKey(_ environment: String, _ repo: String) -> String {
    "wire-recommendation-account:\(environment):\(repo)"
  }

  private func lockRecord(_ environment: String, repo: String, uri: String, on connection: PostgresConnection)
    async throws
  {
    try await connection.query(
      "SELECT pg_advisory_xact_lock(hashtextextended(\(Self.accountLockKey(environment, repo)), 0))",
      logger: logger)
    try await connection.query(
      "SELECT pg_advisory_xact_lock(hashtextextended(\(uri), 0))", logger: logger)
  }

  private func read(environment: String, generation: String, sequence: Int64, on connection: PostgresConnection)
    async throws -> Entry?
  {
    let rows = try await connection.query(
      """
      SELECT environment, source_generation, seq, source_host, cursor_kind, repo_did,
             source_uri, operation, repo_rev, record_cid, event_time, actor_key_hash,
             subject_uri, status, attempt_count
      FROM wire_recommendation_journal
      WHERE environment = \(environment) AND source_generation = \(generation) AND seq = \(sequence)
      """, logger: logger)
    for try await row in rows {
      let v = try row.decode(
        (String, String, Int64, String, String, String, String, String, String?, String?,
         Date, String, String?, String, Int).self)
      return Entry(environment: v.0, generation: v.1, sequence: v.2, host: v.3, cursor: v.4,
        repo: v.5, uri: v.6, operation: v.7, revision: v.8, cid: v.9, time: v.10,
        actor: v.11, subject: v.12, status: v.13, attempts: v.14)
    }
    return nil
  }

  private func reconcile(_ entry: Entry, on connection: PostgresConnection, asOf: Date) async throws -> String {
    try Task.checkCancellation()
    let fenceRows = try await connection.query(
      """
      SELECT source_generation, seq FROM wire_recommendation_record_fences
      WHERE environment = \(entry.environment) AND source_uri = \(entry.uri)
      """, logger: logger)
    var fence: (String, Int64)?
    for try await row in fenceRows { fence = try row.decode((String, Int64).self) }
    if fence == nil {
      // Existing projections predate the journal. Preserve the original
      // timestamp guard until an authoritative journal version is available.
      let newerRows = try await connection.query(
        """
        SELECT EXISTS(SELECT 1 FROM wire_signal_events
          WHERE source_uri = \(entry.uri) AND occurred_at > \(entry.time))
        """, logger: logger)
      for try await row in newerRows where try row.decode(Bool.self) {
        return try await setStatus(entry, "superseded", reason: "newer_existing_signal", on: connection, asOf: asOf)
      }
    }
    if let fence, let previous = try await read(
      environment: entry.environment, generation: fence.0, sequence: fence.1, on: connection)
    {
      switch Self.order(entry, previous) {
      case .older:
        return try await setStatus(entry, "superseded", reason: "newer_record_version", on: connection, asOf: asOf)
      case .conflict:
        return try await setStatus(entry, "conflict", reason: "incomparable_record_versions", on: connection, asOf: asOf)
      case .same:
        if entry.generation != previous.generation || entry.sequence != previous.sequence {
          return try await setStatus(entry, "superseded", reason: "duplicate_record_version", on: connection, asOf: asOf)
        }
      case .newer:
        _ = try await setStatus(previous, "superseded", reason: "newer_record_version", on: connection, asOf: asOf)
      }
    }
    try await connection.query(
      """
      INSERT INTO wire_recommendation_record_fences
        (environment, source_uri, source_generation, seq, updated_at)
      VALUES (\(entry.environment), \(entry.uri), \(entry.generation), \(entry.sequence), \(asOf))
      ON CONFLICT (environment, source_uri) DO UPDATE SET
        source_generation = EXCLUDED.source_generation, seq = EXCLUDED.seq, updated_at = EXCLUDED.updated_at
      WHERE (wire_recommendation_record_fences.source_generation, wire_recommendation_record_fences.seq)
        IS DISTINCT FROM (EXCLUDED.source_generation, EXCLUDED.seq)
      """, logger: logger)
    if entry.operation == "delete" {
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(entry.uri)", logger: logger)
      return try await setStatus(entry, "deleted", reason: nil, on: connection, asOf: asOf)
    }
    let accountRows = try await connection.query(
      """
      SELECT active, inactive_through FROM wire_recommendation_account_fences
      WHERE environment = \(entry.environment) AND repo_did = \(entry.repo)
      """, logger: logger)
    for try await row in accountRows {
      let value = try row.decode((Bool, Date?).self)
      if let cutoff = value.1, entry.time <= cutoff {
        return try await setStatus(entry, "superseded", reason: "account_retracted", on: connection, asOf: asOf)
      }
      if !value.0 {
        return try await setStatus(entry, "pending", reason: "account_inactive", on: connection, asOf: asOf)
      }
    }
    let aliasRows = try await connection.query(
      """
      SELECT canonical_key FROM wire_item_aliases
      WHERE alias_key = \(entry.subject) AND expires_at > \(asOf)
      """, logger: logger)
    var canonical: String?
    for try await row in aliasRows { canonical = try row.decode(String.self) }
    guard let canonical else {
      // Updating a recommendation to an unresolved subject invalidates its old
      // signal immediately; it must not keep endorsing the previous subject.
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(entry.uri)", logger: logger)
      return try await setStatus(entry, "pending", reason: "unresolved_subject", on: connection, asOf: asOf)
    }
    guard entry.time.addingTimeInterval(WireDataPolicy.signalRetention) > asOf else {
      return try await setStatus(entry, "expired", reason: "signal_retention_elapsed", on: connection, asOf: asOf)
    }
    let existingRows = try await connection.query(
      """
      SELECT EXISTS(SELECT 1 FROM wire_signal_events
        WHERE occurred_at = \(entry.time) AND source_uri = \(entry.uri) AND transport_event_key = \(entry.transportKey)
          AND canonical_key = \(canonical))
      """, logger: logger)
    var exists = false
    for try await row in existingRows { exists = try row.decode(Bool.self) }
    if !exists {
      try await connection.query(
        "SELECT ensure_wire_signal_event_partition((\(entry.time) AT TIME ZONE 'UTC')::date)", logger: logger)
      try await connection.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(entry.uri)", logger: logger)
      try await connection.query(
        """
        INSERT INTO wire_signal_events
          (event_key, transport_event_key, canonical_key, signal_kind, actor_key_hash,
           source_uri, source_collection, source_action, occurred_at, expires_at)
        VALUES (\(entry.eventKey), \(entry.transportKey), \(canonical), 'recommendation',
                \(entry.actor), \(entry.uri), 'site.standard.graph.recommend', 'recommendation',
                \(entry.time), \(entry.time.addingTimeInterval(WireDataPolicy.signalRetention)))
        ON CONFLICT DO NOTHING
        """, logger: logger)
      let accountingRows = try await connection.query(
        """
        SELECT actor_recorded FROM wire_recommendation_journal
        WHERE environment = \(entry.environment) AND source_generation = \(entry.generation) AND seq = \(entry.sequence)
        """, logger: logger)
      var actorRecorded = false
      for try await row in accountingRows { actorRecorded = try row.decode(Bool.self) }
      let increment: Int64 = actorRecorded ? 0 : 1
      try await connection.query(
        """
        INSERT INTO wire_active_actors
          (actor_key_hash, first_active_at, last_active_at, public_signal_count, expires_at)
        VALUES (\(entry.actor), \(asOf), \(asOf), 1, \(asOf.addingTimeInterval(WireDataPolicy.activeActorRetention)))
        ON CONFLICT (actor_key_hash) DO UPDATE SET
          last_active_at = GREATEST(wire_active_actors.last_active_at, EXCLUDED.last_active_at),
          public_signal_count = wire_active_actors.public_signal_count + \(increment),
          expires_at = GREATEST(wire_active_actors.expires_at, EXCLUDED.expires_at)
        """, logger: logger)
    }
    try await connection.query(
      """
      UPDATE wire_items SET provenance = provenance || '["recommendation"]'::jsonb, updated_at = \(asOf)
      WHERE canonical_key = \(canonical) AND NOT (provenance ? 'recommendation')
      """, logger: logger)
    return try await setStatus(entry, "resolved", reason: nil, on: connection, asOf: asOf)
  }

  private static func order(_ candidate: Entry, _ current: Entry) -> Ordering {
    // Repository revisions follow the record across transports and replay
    // generations. Transport sequence is a fallback only within one stream.
    if let left = candidate.revision, let right = current.revision,
      validRevision(left), validRevision(right)
    {
      if left != right { return left > right ? .newer : .older }
      return candidate.operation == current.operation && candidate.cid == current.cid
        && candidate.subject == current.subject ? .same : .conflict
    }
    if candidate.host == current.host && candidate.cursor == current.cursor {
      if candidate.sequence == current.sequence {
        return candidate.operation == current.operation && candidate.cid == current.cid
          && candidate.subject == current.subject && candidate.revision == current.revision
          ? .same : .conflict
      }
      return candidate.sequence > current.sequence ? .newer : .older
    }
    return .conflict
  }

  private static func validRevision(_ value: String) -> Bool {
    value.utf8.count == 13 && value.utf8.allSatisfy { "234567abcdefghijklmnopqrstuvwxyz".utf8.contains($0) }
  }

  private func setStatus(_ entry: Entry, _ status: String, reason: String?, on connection: PostgresConnection, asOf: Date)
    async throws -> String
  {
    try Task.checkCancellation()
    let delay = min(3_600.0, 30 * pow(2, Double(min(entry.attempts, 7))))
    try await connection.query(
      """
      UPDATE wire_recommendation_journal
      SET status = \(status), failure_reason = \(reason), updated_at = \(asOf),
          actor_recorded = actor_recorded OR \(status == "resolved"),
          attempt_count = attempt_count + 1,
          next_attempt_at = \(asOf.addingTimeInterval(status == "pending" ? delay : 3_600))
      WHERE environment = \(entry.environment) AND source_generation = \(entry.generation) AND seq = \(entry.sequence)
      """, logger: logger)
    return status
  }
}
