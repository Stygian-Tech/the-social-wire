import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("narrow candidate selection preserves full legacy values and ordering across ranking modes", arguments: [false, true])
  func narrowCandidateParity(globalProjectionEnabled: Bool) async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      let pool = fixture.pool
      let logger = fixture.logger
      let now = fixture.now
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title, first_seen_at,
           last_seen_at, expires_at, language_code, eligible, published_at, provenance,
           thumbnail_url, topic_keys, last_signal_at)
        SELECT \(fixture.prefix) || '-' || n, 'https://example.com/' || \(fixture.prefix) || '/' || n,
          'example.com', 'Fixture', 'Story ' || n, \(now), \(now),
          \(now) + CASE WHEN n % 17 = 0 THEN interval '0 seconds' ELSE interval '1 day' END,
          CASE WHEN n % 2 = 0 THEN 'en' ELSE 'es' END, n % 13 <> 0,
          CASE WHEN n % 5 = 0 THEN NULL ELSE \(now) - (n % 4) * interval '1 day' END,
          CASE WHEN n % 3 = 0 THEN '["standard_site"]'::jsonb ELSE '[]'::jsonb END,
          CASE WHEN n % 4 = 0 THEN ' https://example.com/image.png ' ELSE NULL END,
          jsonb_build_array('topic-' || n), \(now) - n * interval '1 second'
        FROM generate_series(1, 60) n
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_signal_rollups
          (canonical_key, shares_24h, recommendations_24h, signals_1h,
           baseline_shares_24h, baseline_recommendations_24h, baseline_signals_1h,
           baseline_last_signal_at, distinct_reposters_24h, reposts_1h, reposts_24h)
        SELECT \(fixture.prefix) || '-' || n, n % 7, n % 3, n % 5,
          n % 4, n % 2, n % 6, CASE WHEN n % 5 = 0 THEN NULL ELSE \(now) END,
          n, n, n FROM generate_series(1, 60) n WHERE n % 19 <> 0
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, title, description, source, status, stale_until)
        SELECT \(fixture.prefix) || '-' || n, 'https://example.com/' || n,
          'Metadata', CASE WHEN n % 4 = 0 THEN NULL ELSE 'Description' END,
          'open_graph', CASE WHEN n % 3 = 0 THEN 'stale' ELSE 'fresh' END,
          \(now) + CASE WHEN n % 5 = 0 THEN interval '0 seconds' ELSE interval '1 day' END
        FROM generate_series(1, 60) n WHERE n % 2 = 0
        ON CONFLICT (canonical_key) DO UPDATE SET title = EXCLUDED.title,
          description = EXCLUDED.description, source = EXCLUDED.source,
          status = EXCLUDED.status, stale_until = EXCLUDED.stale_until
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_labels (canonical_key, label_key, label_value, source, applied_at, expires_at)
        SELECT \(fixture.prefix) || '-' || n, 'moderation', 'block', 'fixture', \(now),
          \(now) + CASE WHEN n % 2 = 0 THEN interval '0 seconds' ELSE interval '1 day' END
        FROM generate_series(1, 60) n WHERE n % 7 = 0
        """, logger: logger)
      let store = PostgresWireGenerationStore(
        pool: pool, logger: logger, globalCandidateProjectionEnabled: globalProjectionEnabled)
      for ranking in [WireRankingConfig(), WireRankingConfig.externalSignalsV11()] {
        for language in ["und", "en", "es", "zz"] {
          for limit in [0, 1, 7, 5000] {
            let expected = try await legacyLoadCandidates(pool: pool, logger: logger,
              languageBucket: language, limit: limit, ranking: ranking, asOf: now)
            let actual = try await store.loadCandidates(
              languageBucket: language, limit: limit, ranking: ranking, asOf: now)
            #expect(actual == expected,
              "mode=\(ranking.version) language=\(language) limit=\(limit)")
          }
        }
      }
    }
  }

  // Frozen pre-optimization query/decode oracle: verifies all candidate fields as well
  // as ties and cutoffs without deriving the expected answer from the new CTE.
  private func legacyLoadCandidates(
    pool: PostgresClient, logger: Logger,
    languageBucket: String,
    limit: Int,
    ranking: WireRankingConfig,
    asOf: Date
  ) async throws -> [WireCandidate] {
    let includeExternalSignals = ranking.version == WireRankingConfig.externalSignalVersion
    let freshPublicationCutoff = asOf.addingTimeInterval(-72 * 60 * 60)
    let rows = try await pool.query(
      """
      SELECT i.canonical_key, i.canonical_url, i.representative_uri, i.source_domain,
             i.publication_id, i.author_key, i.topic_keys::text, i.published_at,
             i.first_seen_at,
             CASE WHEN \(includeExternalSignals) THEN i.last_signal_at
                  ELSE r.baseline_last_signal_at END,
             i.source_confidence,
             (i.provenance ? 'standard_site') AS is_standard_site,
             COALESCE(metadata.source = 'open_graph'
               AND metadata.status IN ('fresh', 'stale')
               AND metadata.stale_until > \(asOf)
               AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
                 metadata.site_name, metadata.author_name, metadata.published_at::TEXT,
                 metadata.icon_url) >= 2, FALSE) AS has_usable_open_graph,
             i.target_kind, i.commercial_class, i.commercial_score,
             CASE WHEN \(includeExternalSignals) THEN r.distinct_actors_1h
                  ELSE r.baseline_distinct_actors_1h END,
             CASE WHEN \(includeExternalSignals) THEN r.distinct_actors_24h
                  ELSE r.baseline_distinct_actors_24h END,
             CASE WHEN \(includeExternalSignals) THEN r.distinct_actors_7d
                  ELSE r.baseline_distinct_actors_7d END,
             CASE WHEN \(includeExternalSignals) THEN r.signals_1h ELSE r.baseline_signals_1h END,
             CASE WHEN \(includeExternalSignals) THEN r.signals_24h ELSE r.baseline_signals_24h END,
             CASE WHEN \(includeExternalSignals) THEN r.signals_7d ELSE r.baseline_signals_7d END,
             r.communities_24h, r.primary_community_key_hash,
             CASE WHEN \(includeExternalSignals) THEN r.recommendations_24h
                  ELSE r.baseline_recommendations_24h END,
             r.positive_feedback_24h, r.negative_feedback_24h,
             CASE WHEN \(includeExternalSignals) THEN r.shares_1h ELSE r.baseline_shares_1h END,
             CASE WHEN \(includeExternalSignals) THEN r.shares_24h ELSE r.baseline_shares_24h END,
             CASE WHEN \(includeExternalSignals) THEN r.distinct_likers_24h
                  ELSE r.baseline_distinct_likers_24h END,
             CASE WHEN \(includeExternalSignals) THEN r.likes_1h ELSE r.baseline_likes_1h END,
             CASE WHEN \(includeExternalSignals) THEN r.likes_24h ELSE r.baseline_likes_24h END,
             r.distinct_reposters_24h, r.reposts_1h, r.reposts_24h,
             COALESCE(NULLIF(BTRIM(i.thumbnail_url), '') ~* '^https?://', FALSE)
               AS has_usable_thumbnail
      FROM wire_items i
      JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
      LEFT JOIN wire_link_metadata_cache metadata ON metadata.canonical_key = i.canonical_key
      WHERE i.eligible = TRUE AND i.expires_at > \(asOf)
        AND i.target_kind IN ('external_article', 'standard_site_document')
        AND i.commercial_class <> 'probable_ad'
        AND (\(languageBucket) = 'und' OR i.language_code = \(languageBucket))
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels l
          WHERE l.canonical_key = i.canonical_key AND l.expires_at > \(asOf)
            AND l.label_key IN ('moderation', 'visibility')
            AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      ORDER BY
        CASE
          WHEN (CASE WHEN \(includeExternalSignals) THEN r.shares_24h
                     ELSE r.baseline_shares_24h END) >= 5
            OR (CASE WHEN \(includeExternalSignals) THEN r.recommendations_24h
                     ELSE r.baseline_recommendations_24h END) >= 2 THEN 0
          WHEN (i.provenance ? 'standard_site')
            AND i.published_at >= \(freshPublicationCutoff)
            AND (CASE WHEN \(includeExternalSignals) THEN r.shares_24h
                      ELSE r.baseline_shares_24h END) >= 1 THEN 1
          WHEN ((CASE WHEN \(includeExternalSignals) THEN r.shares_24h
                      ELSE r.baseline_shares_24h END) >= 3
            OR (CASE WHEN \(includeExternalSignals) THEN r.recommendations_24h
                     ELSE r.baseline_recommendations_24h END) >= 1) THEN 2
          ELSE 3
        END,
        (CASE WHEN \(includeExternalSignals) THEN r.shares_24h
              ELSE r.baseline_shares_24h END) DESC,
        (CASE WHEN \(includeExternalSignals) THEN r.recommendations_24h
              ELSE r.baseline_recommendations_24h END) DESC,
        (i.provenance ? 'standard_site') DESC,
        has_usable_thumbnail DESC, has_usable_open_graph DESC,
        (CASE WHEN \(includeExternalSignals) THEN r.signals_1h
              ELSE r.baseline_signals_1h END) DESC,
        i.canonical_key
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
      let isStandardSite = try cells[11].decode(Bool.self)
      let hasUsableOpenGraph = try cells[12].decode(Bool.self)
      let hasUsableThumbnail = try cells[35].decode(Bool.self)
      let targetKind = WireTargetKind(rawValue: try cells[13].decode(String.self)) ?? .unsupported
      let commercialClass =
        WireCommercialClass(
          rawValue: try cells[14].decode(String.self)) ?? .probableAd
      let commercialScore = try cells[15].decode(Double.self)
      let rollup = try (
        cells[16].decode(Int.self), cells[17].decode(Int.self),
        cells[18].decode(Int.self), cells[19].decode(Int.self),
        cells[20].decode(Int.self), cells[21].decode(Int.self),
        cells[22].decode(Int.self), cells[23].decode(String?.self),
        cells[24].decode(Int.self), cells[25].decode(Int.self),
        cells[26].decode(Int.self), cells[27].decode(Int.self),
        cells[28].decode(Int.self), cells[29].decode(Int.self),
        cells[30].decode(Int.self), cells[31].decode(Int.self),
        cells[32].decode(Int.self), cells[33].decode(Int.self),
        cells[34].decode(Int.self)
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
          positiveFeedback24h: rollup.9,
          negativeFeedback24h: rollup.10,
          shares1h: rollup.11,
          shares24h: rollup.12,
          distinctLikes24h: rollup.13,
          likes1h: rollup.14,
          likes24h: rollup.15,
          distinctReposts24h: rollup.16,
          reposts1h: rollup.17,
          reposts24h: rollup.18,
          sourceConfidence: identity.10,
          isStandardSite: isStandardSite,
          hasUsableOpenGraphMetadata: hasUsableOpenGraph,
          hasUsableThumbnail: hasUsableThumbnail,
          targetKind: targetKind,
          commercialClass: commercialClass,
          commercialScore: commercialScore
        )
      )
    }
    return candidates
  }

}
