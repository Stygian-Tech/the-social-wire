import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWireGenerationStore: WireGenerationStore {
  let pool: PostgresClient
  let logger: Logger

  func ping() async throws {
    let rows = try await pool.query("SELECT 1", logger: logger)
    for try await _ in rows { return }
  }

  func eligibleLanguageBuckets(
    limit: Int,
    minimumCandidates: Int,
    asOf: Date
  ) async throws -> [String] {
    let rows = try await pool.query(
      """
      SELECT i.language_code
      FROM wire_items i
      JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
      WHERE i.eligible = TRUE AND i.expires_at > \(asOf)
        AND i.language_code <> 'und'
        AND i.source_confidence >= 0.25
        AND (r.distinct_actors_24h >= 3 OR r.recommendations_24h >= 1
          OR (i.source_confidence >= 0.75
            AND i.representative_uri LIKE 'at://%/site.standard.%'
            AND COALESCE(i.published_at, i.first_seen_at) >= \(asOf.addingTimeInterval(-86_400))))
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels l
          WHERE l.canonical_key = i.canonical_key AND l.expires_at > \(asOf)
            AND l.label_key IN ('moderation', 'visibility')
            AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      GROUP BY i.language_code
      HAVING COUNT(*) >= \(minimumCandidates)
      ORDER BY COUNT(*) DESC, i.language_code
      LIMIT \(max(0, min(limit, 12)))
      """,
      logger: logger
    )
    var result: [String] = []
    for try await row in rows { result.append(try row.decode(String.self)) }
    return result
  }

  func loadCandidates(
    languageBucket: String,
    limit: Int,
    asOf: Date
  ) async throws -> [WireCandidate] {
    let rows = try await pool.query(
      """
      SELECT i.canonical_key, i.canonical_url, i.representative_uri, i.source_domain,
             i.publication_id, i.author_key, i.topic_keys::text, i.published_at,
             i.first_seen_at, i.last_signal_at, i.source_confidence,
             r.distinct_actors_1h, r.distinct_actors_24h, r.distinct_actors_7d,
             r.signals_1h, r.signals_24h, r.signals_7d, r.communities_24h,
             r.primary_community_key_hash, r.recommendations_24h,
             r.shares_1h, r.shares_24h, r.distinct_likers_24h, r.likes_1h, r.likes_24h,
             r.distinct_reposters_24h, r.reposts_1h, r.reposts_24h
      FROM wire_items i
      JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
      WHERE i.eligible = TRUE AND i.expires_at > \(asOf)
        AND (\(languageBucket) = 'und' OR i.language_code = \(languageBucket))
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels l
          WHERE l.canonical_key = i.canonical_key AND l.expires_at > \(asOf)
            AND l.label_key IN ('moderation', 'visibility')
            AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      ORDER BY r.distinct_actors_24h DESC, r.signals_1h DESC, i.canonical_key
      LIMIT \(limit)
      """,
      logger: logger
    )
    var candidates: [WireCandidate] = []
    for try await row in rows {
      let identity = try row.decode(
        (String, String, String?, String, String?, String?, String, Date?, Date, Date?, Double).self
      )
      let cells = row.makeRandomAccess()
      let rollup = try (
        cells[11].decode(Int.self), cells[12].decode(Int.self),
        cells[13].decode(Int.self), cells[14].decode(Int.self),
        cells[15].decode(Int.self), cells[16].decode(Int.self),
        cells[17].decode(Int.self), cells[18].decode(String?.self),
        cells[19].decode(Int.self), cells[20].decode(Int.self),
        cells[21].decode(Int.self), cells[22].decode(Int.self),
        cells[23].decode(Int.self), cells[24].decode(Int.self),
        cells[25].decode(Int.self), cells[26].decode(Int.self),
        cells[27].decode(Int.self)
      )
      let topics = (try? JSONDecoder().decode([String].self, from: Data(identity.6.utf8))) ?? []
      candidates.append(
        WireCandidate(
          canonicalKey: identity.0,
          canonicalURL: identity.1,
          representativeURI: identity.2,
          sourceDomain: identity.3,
          publicationID: identity.4,
          authorKey: identity.5,
          topicKeys: topics,
          publishedAt: identity.7,
          firstSeenAt: identity.8,
          lastSignalAt: identity.9,
          distinctActors1h: rollup.0,
          distinctActors24h: rollup.1,
          distinctActors7d: rollup.2,
          signals1h: rollup.3,
          signals24h: rollup.4,
          signals7d: rollup.5,
          communities24h: rollup.6,
          primaryCommunityKey: rollup.7,
          recommendations24h: rollup.8,
          shares1h: rollup.9,
          shares24h: rollup.10,
          distinctLikes24h: rollup.11,
          likes1h: rollup.12,
          likes24h: rollup.13,
          distinctReposts24h: rollup.14,
          reposts1h: rollup.15,
          reposts24h: rollup.16,
          sourceConfidence: identity.10
        )
      )
    }
    return candidates
  }

  func commit(_ generation: WireGenerationCommit) async throws {
    let diagnostics = try json(generation.result.diagnostics)
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO wire_feed_state (feed_key, language_bucket, active_generation_id, updated_at)
        VALUES (\(generation.feedKey), \(generation.languageBucket), NULL, \(generation.generatedAt))
        ON CONFLICT (feed_key, language_bucket) DO NOTHING
        """,
        logger: logger
      )
      _ = try await connection.query(
        """
        SELECT active_generation_id FROM wire_feed_state
        WHERE feed_key = \(generation.feedKey) AND language_bucket = \(generation.languageBucket)
        FOR UPDATE
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_rank_generations
          (generation_id, feed_key, language_bucket, status, is_active, config_version,
           generated_at, committed_at, expires_at, candidate_count, ranked_count, diagnostics)
        VALUES
          (\(generation.generationID), \(generation.feedKey), \(generation.languageBucket),
           'building', FALSE, \(generation.configVersion), \(generation.generatedAt), NULL,
           \(generation.expiresAt), \(generation.result.diagnostics.candidateCount),
           \(generation.result.items.count), \(diagnostics)::jsonb)
        """,
        logger: logger
      )
      for (position, item) in generation.result.items.enumerated() {
        let reasons = try json(item.reasonCodes.map(\.rawValue))
        try await connection.query(
          """
          INSERT INTO wire_ranked_items
            (generation_id, position, canonical_key, score, reason_codes, diversity_metadata)
          VALUES
            (\(generation.generationID), \(position), \(item.candidate.canonicalKey), \(item.score),
             \(reasons)::jsonb, '{}'::jsonb)
          """,
          logger: logger
        )
      }

      if generation.activate {
        try await connection.query(
          """
          UPDATE wire_rank_generations
          SET status = 'superseded', is_active = FALSE
          WHERE feed_key = \(generation.feedKey) AND language_bucket = \(generation.languageBucket)
            AND is_active = TRUE
          """,
          logger: logger
        )
        try await connection.query(
          """
          UPDATE wire_rank_generations
          SET status = 'committed', is_active = TRUE, committed_at = \(generation.generatedAt)
          WHERE generation_id = \(generation.generationID)
          """,
          logger: logger
        )
        try await connection.query(
          """
          UPDATE wire_feed_state
          SET active_generation_id = \(generation.generationID), updated_at = \(generation.generatedAt)
          WHERE feed_key = \(generation.feedKey) AND language_bucket = \(generation.languageBucket)
          """,
          logger: logger
        )
      } else {
        try await connection.query(
          """
          UPDATE wire_rank_generations
          SET status = 'shadow', committed_at = \(generation.generatedAt)
          WHERE generation_id = \(generation.generationID)
          """,
          logger: logger
        )
      }
    }
  }

  func deleteExpired(asOf: Date, batchSize: Int) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        DELETE FROM wire_rank_generations
        WHERE generation_id IN (
          SELECT generation_id FROM wire_rank_generations
          WHERE expires_at <= \(asOf) AND is_active = FALSE
          ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_ingestion_inbox
        WHERE (environment, source_generation, seq) IN (
          SELECT environment, source_generation, seq FROM wire_ingestion_inbox
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_signal_events
        WHERE (occurred_at, id) IN (
          SELECT occurred_at, id FROM wire_signal_events WHERE expires_at <= \(asOf)
          ORDER BY expires_at, occurred_at, id LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_follow_edges
        WHERE (follower_key_hash, followee_key_hash) IN (
          SELECT follower_key_hash, followee_key_hash FROM wire_follow_edges
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_actor_communities
        WHERE actor_key_hash IN (
          SELECT actor_key_hash FROM wire_actor_communities
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_active_actors
        WHERE actor_key_hash IN (
          SELECT actor_key_hash FROM wire_active_actors
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_item_aliases
        WHERE alias_key IN (
          SELECT alias_key FROM wire_item_aliases
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_labels
        WHERE (canonical_key, label_key, source) IN (
          SELECT canonical_key, label_key, source FROM wire_labels
          WHERE expires_at <= \(asOf) ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_items
        WHERE canonical_key IN (
          SELECT canonical_key FROM wire_items WHERE expires_at <= \(asOf)
          ORDER BY expires_at LIMIT \(batchSize)
        )
        """,
        logger: logger
      )
    }
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
}
