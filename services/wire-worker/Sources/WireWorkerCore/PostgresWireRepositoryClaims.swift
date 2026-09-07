import Foundation
import PostgresNIO

extension PostgresWireInboxProcessor: WireInboxRepositoryProcessing {
  func claimWork(
    asOf: Date, limit: Int, afterRepository: WireInboxRepository? = nil
  ) async throws -> WireInboxWorkBatch {
    try Task.checkCancellation()
    let available = min(batchSize, maximumConcurrentEvents, max(0, limit))
    guard available > 0 else { return .init(events: [], appliedPassiveEventCount: 0) }
    let passiveCount = try await acknowledgeUnresolvedPassiveReferences(
      asOf: asOf, limit: batchSize)
    try Task.checkCancellation()
    // Keep the existing passive-delete prefix priority, within the same total
    // execution-slot ceiling as ordinary repository heads.
    let passive = try await claimScopedPassiveDeletes(asOf: asOf, limit: available)
    let remaining = available - passive.count
    var heads: [WireInboxEvent] = []
    if remaining > 0 {
      try Task.checkCancellation()
      heads = try await claimRepositoryHeads(asOf: asOf, limit: remaining, after: afterRepository)
      // One wrap per admission attempt gives later identities an opportunity
      // before a hot repository is admitted for another bounded turn.
      if heads.isEmpty, afterRepository != nil {
        try Task.checkCancellation()
        heads = try await claimRepositoryHeads(asOf: asOf, limit: remaining, after: nil)
      }
    }
    return .init(
      events: passive + heads, appliedPassiveEventCount: passiveCount,
      nextRepositoryCursor: heads.last?.repository ?? afterRepository)
  }

  func claimNext(in repository: WireInboxRepository, asOf: Date) async throws -> WireInboxEvent? {
    try Task.checkCancellation()
    if let sourceScope,
      sourceScope.environment != repository.environment
        || !sourceScope.sourceGenerations.contains(repository.sourceGeneration)
    {
      return nil
    }
    let token = UUID().uuidString.lowercased()
    let rows = try await pool.query(
      """
      WITH repository_head AS MATERIALIZED (
        SELECT seq
        FROM wire_ingestion_inbox
        WHERE environment = \(repository.environment)
          AND source_generation = \(repository.sourceGeneration)
          AND repo_did = \(repository.repoDID)
          AND status IN ('pending', 'leased', 'retry')
        ORDER BY seq
        LIMIT 1
      ), candidate AS (
        SELECT inbox.environment, inbox.source_generation, inbox.seq
        FROM wire_ingestion_inbox inbox JOIN repository_head head ON head.seq = inbox.seq
        WHERE inbox.environment = \(repository.environment)
          AND inbox.source_generation = \(repository.sourceGeneration)
          AND inbox.repo_did = \(repository.repoDID)
          AND ((inbox.status IN ('pending', 'retry') AND inbox.next_attempt_at <= \(asOf))
            OR (inbox.status = 'leased' AND inbox.lease_expires_at <= \(asOf)))
        FOR UPDATE OF inbox SKIP LOCKED
      )
      UPDATE wire_ingestion_inbox inbox
      SET status = 'leased', lease_owner = 'wire-worker', lease_token = \(token),
          lease_expires_at = \(asOf.addingTimeInterval(120)),
          attempt_count = attempt_count + 1, updated_at = \(asOf)
      FROM candidate
      WHERE inbox.environment = candidate.environment
        AND inbox.source_generation = candidate.source_generation AND inbox.seq = candidate.seq
      RETURNING inbox.environment, inbox.source_generation, inbox.seq,
                inbox.source_host, inbox.cursor_kind, inbox.event_kind,
                inbox.repo_did, inbox.collection, inbox.operation, inbox.record_key,
                inbox.payload::text, inbox.event_time, inbox.lease_token, inbox.attempt_count
      """, logger: logger)
    return try await Self.decodeClaimedEvents(rows).first
  }

  private func claimRepositoryHeads(
    asOf: Date, limit: Int, after: WireInboxRepository?
  ) async throws -> [WireInboxEvent] {
    let token = UUID().uuidString.lowercased()
    var query = PostgresQuery.StringInterpolation(literalCapacity: 3_000, interpolationCount: 12)
    query.appendLiteral(
      """
      WITH repository_heads AS MATERIALIZED (
        SELECT DISTINCT ON (candidate.environment, candidate.source_generation, candidate.repo_did)
               candidate.environment, candidate.source_generation, candidate.repo_did, candidate.seq
        FROM wire_ingestion_inbox candidate
        WHERE candidate.status IN ('pending', 'leased', 'retry')
      """)
    // Omit absent predicates entirely: nullable-parameter ORs force generic
    // plans to scan and sort unrelated source generations. Values stay bound.
    if let sourceScope {
      query.appendLiteral(" AND candidate.environment = ")
      query.appendInterpolation(sourceScope.environment)
      query.appendLiteral(" AND candidate.source_generation = ANY(")
      query.appendInterpolation(sourceScope.sourceGenerations)
      query.appendLiteral(")")
    }
    if let after {
      query.appendLiteral(
        " AND (candidate.environment, candidate.source_generation, candidate.repo_did) > (")
      query.appendInterpolation(after.environment)
      query.appendLiteral(", ")
      query.appendInterpolation(after.sourceGeneration)
      query.appendLiteral(", ")
      query.appendInterpolation(after.repoDID)
      query.appendLiteral(")")
    }
    query.appendLiteral(
      """

        ORDER BY candidate.environment, candidate.source_generation, candidate.repo_did, candidate.seq
      ), candidates AS (
        SELECT candidate.environment, candidate.source_generation, candidate.seq
        FROM repository_heads head JOIN wire_ingestion_inbox candidate
          ON candidate.environment = head.environment
          AND candidate.source_generation = head.source_generation AND candidate.seq = head.seq
        WHERE (candidate.status IN ('pending', 'retry') AND candidate.next_attempt_at <=
      """)
    query.appendInterpolation(asOf)
    query.appendLiteral(") OR (candidate.status = 'leased' AND candidate.lease_expires_at <= ")
    query.appendInterpolation(asOf)
    query.appendLiteral(
      """
        )
        ORDER BY candidate.environment, candidate.source_generation, candidate.repo_did
        FOR UPDATE OF candidate SKIP LOCKED
        LIMIT
      """)
    query.appendLiteral(" ")
    query.appendInterpolation(limit)
    query.appendLiteral(
      """
      ), claimed AS (
        UPDATE wire_ingestion_inbox inbox
        SET status = 'leased', lease_owner = 'wire-worker', lease_token =
      """)
    query.appendInterpolation(token)
    query.appendLiteral(", lease_expires_at = ")
    query.appendInterpolation(asOf.addingTimeInterval(120))
    query.appendLiteral(", attempt_count = attempt_count + 1, updated_at = ")
    query.appendInterpolation(asOf)
    query.appendLiteral(
      """

        FROM candidates
        WHERE inbox.environment = candidates.environment
          AND inbox.source_generation = candidates.source_generation AND inbox.seq = candidates.seq
        RETURNING inbox.*
      )
      SELECT environment, source_generation, seq, source_host, cursor_kind, event_kind,
             repo_did, collection, operation, record_key, payload::text, event_time,
             lease_token, attempt_count
      FROM claimed ORDER BY environment, source_generation, repo_did
      """)
    let rows = try await pool.query(PostgresQuery(stringInterpolation: query), logger: logger)
    return try await Self.decodeClaimedEvents(rows)
  }

  private static func decodeClaimedEvents(_ rows: PostgresRowSequence) async throws
    -> [WireInboxEvent]
  {
    var events: [WireInboxEvent] = []
    for try await row in rows {
      let value = try row.decode(
        (
          String, String, Int64, String, String, String, String, String?, String?, String?, String,
          Date, String, Int
        ).self)
      events.append(
        .init(
          environment: value.0, sourceGeneration: value.1, sequence: value.2,
          sourceHost: value.3, cursorKind: value.4, eventKind: value.5, repoDID: value.6,
          collection: value.7, operation: value.8, recordKey: value.9, payloadJSON: value.10,
          eventTime: value.11, leaseToken: value.12, attemptCount: value.13))
    }
    return events
  }
}
