package wireworkercore

// Keeps PostgreSQL candidate projection contracts and bind ordering next to their
// scanners. Both candidate queries exclude expired/ineligible/moderated items and switch
// baseline versus external rollups together; locale discovery applies quality and signal
// floors before choosing at most twelve buckets.

// Typed binds and metadata projection preserve PostgresWireCandidateQuery.
const candidateQuery = `
      WITH candidate_keys AS MATERIALIZED (
        SELECT i.canonical_key,
          CASE
            WHEN (CASE WHEN $1 THEN r.shares_24h
                       ELSE r.baseline_shares_24h END) >= 5
              OR (CASE WHEN $1 THEN r.recommendations_24h
                       ELSE r.baseline_recommendations_24h END) >= 2 THEN 0
            WHEN (i.provenance ? 'standard_site')
              AND i.published_at >= $3
              AND (CASE WHEN $1 THEN r.shares_24h
                        ELSE r.baseline_shares_24h END) >= 1 THEN 1
            WHEN ((CASE WHEN $1 THEN r.shares_24h
                        ELSE r.baseline_shares_24h END) >= 3
              OR (CASE WHEN $1 THEN r.recommendations_24h
                       ELSE r.baseline_recommendations_24h END) >= 1) THEN 2
            ELSE 3
          END AS priority,
          (CASE WHEN $1 THEN r.shares_24h
                ELSE r.baseline_shares_24h END) AS shares_24h,
          (CASE WHEN $1 THEN r.recommendations_24h
                ELSE r.baseline_recommendations_24h END) AS recommendations_24h,
          (i.provenance ? 'standard_site') AS is_standard_site,
          COALESCE(NULLIF(BTRIM(i.thumbnail_url), '') ~* '^https?://', FALSE)
            AS has_usable_thumbnail,

          COALESCE(metadata.stale_until > $2, FALSE) AS has_usable_open_graph,
          (CASE WHEN $1 THEN r.signals_1h
                ELSE r.baseline_signals_1h END) AS signals_1h
        FROM wire_items i
        JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
        LEFT JOIN (
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache
          WHERE open_graph_qualified = TRUE
          UNION ALL
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache metadata
          WHERE open_graph_qualified IS NULL AND metadata.source = 'open_graph'
            AND metadata.status IN ('fresh', 'stale')
            AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
              metadata.site_name, metadata.author_name, metadata.published_at::text,
              metadata.icon_url) >= 2
        ) metadata ON metadata.canonical_key = i.canonical_key
        WHERE i.eligible = TRUE AND i.expires_at > $2
          AND i.target_kind IN ('external_article', 'standard_site_document')
          AND i.commercial_class <> 'probable_ad'
          AND ($4 = 'und' OR i.language_code = $4)
          AND NOT EXISTS (
            SELECT 1 FROM wire_labels l
            WHERE l.canonical_key = i.canonical_key AND l.expires_at > $2
              AND l.label_key IN ('moderation', 'visibility')
              AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
          )
        ORDER BY priority, shares_24h DESC, recommendations_24h DESC,
          is_standard_site DESC, has_usable_thumbnail DESC, has_usable_open_graph DESC,
          signals_1h DESC, i.canonical_key
        LIMIT $5
      )
      SELECT i.canonical_key, i.canonical_url, i.representative_uri, i.source_domain,
             i.publication_id, i.author_key, i.topic_keys::text, i.published_at,
             i.first_seen_at,
             CASE WHEN $1 THEN i.last_signal_at
                  ELSE r.baseline_last_signal_at END,
             i.source_confidence,
             selected.is_standard_site,
             selected.has_usable_open_graph,
             i.target_kind, i.commercial_class, i.commercial_score,
             CASE WHEN $1 THEN r.distinct_actors_1h
                  ELSE r.baseline_distinct_actors_1h END,
             CASE WHEN $1 THEN r.distinct_actors_24h
                  ELSE r.baseline_distinct_actors_24h END,
             CASE WHEN $1 THEN r.distinct_actors_7d
                  ELSE r.baseline_distinct_actors_7d END,
             CASE WHEN $1 THEN r.signals_1h ELSE r.baseline_signals_1h END,
             CASE WHEN $1 THEN r.signals_24h ELSE r.baseline_signals_24h END,
             CASE WHEN $1 THEN r.signals_7d ELSE r.baseline_signals_7d END,
             r.communities_24h, r.primary_community_key_hash,
             CASE WHEN $1 THEN r.recommendations_24h
                  ELSE r.baseline_recommendations_24h END,
             r.positive_feedback_24h, r.negative_feedback_24h,
             CASE WHEN $1 THEN r.shares_1h ELSE r.baseline_shares_1h END,
             CASE WHEN $1 THEN r.shares_24h ELSE r.baseline_shares_24h END,
             CASE WHEN $1 THEN r.distinct_likers_24h
                  ELSE r.baseline_distinct_likers_24h END,
             CASE WHEN $1 THEN r.likes_1h ELSE r.baseline_likes_1h END,
             CASE WHEN $1 THEN r.likes_24h ELSE r.baseline_likes_24h END,
             r.distinct_reposters_24h, r.reposts_1h, r.reposts_24h,
             selected.has_usable_thumbnail
      FROM candidate_keys selected
      JOIN wire_items i ON i.canonical_key = selected.canonical_key
      JOIN wire_signal_rollups r ON r.canonical_key = selected.canonical_key
      ORDER BY selected.priority, selected.shares_24h DESC, selected.recommendations_24h DESC,
        selected.is_standard_site DESC, selected.has_usable_thumbnail DESC,
        selected.has_usable_open_graph DESC, selected.signals_1h DESC, selected.canonical_key
      `

const projectedCandidateQuery = `
      WITH candidate_keys AS MATERIALIZED (
        SELECT i.canonical_key,
          CASE
            WHEN (CASE WHEN $1 THEN r.shares_24h
                       ELSE r.baseline_shares_24h END) >= 5
              OR (CASE WHEN $1 THEN r.recommendations_24h
                       ELSE r.baseline_recommendations_24h END) >= 2 THEN 0
            WHEN (i.provenance ? 'standard_site')
              AND i.published_at >= $3
              AND (CASE WHEN $1 THEN r.shares_24h
                        ELSE r.baseline_shares_24h END) >= 1 THEN 1
            WHEN ((CASE WHEN $1 THEN r.shares_24h
                        ELSE r.baseline_shares_24h END) >= 3
              OR (CASE WHEN $1 THEN r.recommendations_24h
                       ELSE r.baseline_recommendations_24h END) >= 1) THEN 2
            ELSE 3
          END AS priority,
          (CASE WHEN $1 THEN r.shares_24h
                ELSE r.baseline_shares_24h END) AS shares_24h,
          (CASE WHEN $1 THEN r.recommendations_24h
                ELSE r.baseline_recommendations_24h END) AS recommendations_24h,
          (i.provenance ? 'standard_site') AS is_standard_site,
          COALESCE(NULLIF(BTRIM(i.thumbnail_url), '') ~* '^https?://', FALSE)
            AS has_usable_thumbnail,
          COALESCE(metadata.has_usable_open_graph, FALSE) AS has_usable_open_graph,
          (CASE WHEN $1 THEN r.signals_1h
                ELSE r.baseline_signals_1h END) AS signals_1h
        FROM wire_items i
        JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
        LEFT JOIN (SELECT metadata.canonical_key,
          COALESCE(metadata.stale_until > $2, FALSE) AS has_usable_open_graph FROM (
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache
          WHERE open_graph_qualified = TRUE
          UNION ALL
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache metadata
          WHERE open_graph_qualified IS NULL AND metadata.source = 'open_graph'
            AND metadata.status IN ('fresh', 'stale')
            AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
              metadata.site_name, metadata.author_name, metadata.published_at::text,
              metadata.icon_url) >= 2
        ) metadata OFFSET 0) metadata ON metadata.canonical_key = i.canonical_key
        WHERE i.eligible = TRUE AND i.expires_at > $2
          AND i.target_kind IN ('external_article', 'standard_site_document')
          AND i.commercial_class <> 'probable_ad'
          AND ($4 = 'und' OR i.language_code = $4)
          AND NOT EXISTS (
            SELECT 1 FROM wire_labels l
            WHERE l.canonical_key = i.canonical_key AND l.expires_at > $2
              AND l.label_key IN ('moderation', 'visibility')
              AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
          )
        ORDER BY priority, shares_24h DESC, recommendations_24h DESC,
          is_standard_site DESC, has_usable_thumbnail DESC, has_usable_open_graph DESC,
          signals_1h DESC, i.canonical_key
        LIMIT $5
      )
      SELECT i.canonical_key, i.canonical_url, i.representative_uri, i.source_domain,
             i.publication_id, i.author_key, i.topic_keys::text, i.published_at,
             i.first_seen_at,
             CASE WHEN $1 THEN i.last_signal_at
                  ELSE r.baseline_last_signal_at END,
             i.source_confidence,
             selected.is_standard_site,
             selected.has_usable_open_graph,
             i.target_kind, i.commercial_class, i.commercial_score,
             CASE WHEN $1 THEN r.distinct_actors_1h
                  ELSE r.baseline_distinct_actors_1h END,
             CASE WHEN $1 THEN r.distinct_actors_24h
                  ELSE r.baseline_distinct_actors_24h END,
             CASE WHEN $1 THEN r.distinct_actors_7d
                  ELSE r.baseline_distinct_actors_7d END,
             CASE WHEN $1 THEN r.signals_1h ELSE r.baseline_signals_1h END,
             CASE WHEN $1 THEN r.signals_24h ELSE r.baseline_signals_24h END,
             CASE WHEN $1 THEN r.signals_7d ELSE r.baseline_signals_7d END,
             r.communities_24h, r.primary_community_key_hash,
             CASE WHEN $1 THEN r.recommendations_24h
                  ELSE r.baseline_recommendations_24h END,
             r.positive_feedback_24h, r.negative_feedback_24h,
             CASE WHEN $1 THEN r.shares_1h ELSE r.baseline_shares_1h END,
             CASE WHEN $1 THEN r.shares_24h ELSE r.baseline_shares_24h END,
             CASE WHEN $1 THEN r.distinct_likers_24h
                  ELSE r.baseline_distinct_likers_24h END,
             CASE WHEN $1 THEN r.likes_1h ELSE r.baseline_likes_1h END,
             CASE WHEN $1 THEN r.likes_24h ELSE r.baseline_likes_24h END,
             r.distinct_reposters_24h, r.reposts_1h, r.reposts_24h,
             selected.has_usable_thumbnail
      FROM candidate_keys selected
      JOIN wire_items i ON i.canonical_key = selected.canonical_key
      JOIN wire_signal_rollups r ON r.canonical_key = selected.canonical_key
      ORDER BY selected.priority, selected.shares_24h DESC, selected.recommendations_24h DESC,
        selected.is_standard_site DESC, selected.has_usable_thumbnail DESC,
        selected.has_usable_open_graph DESC, selected.signals_1h DESC, selected.canonical_key
      `

const eligibleLanguagesQuery = `
      SELECT i.language_code
      FROM wire_items i
      JOIN wire_signal_rollups r ON r.canonical_key = i.canonical_key
      LEFT JOIN (
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache
          WHERE open_graph_qualified = TRUE
          UNION ALL
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache metadata
          WHERE open_graph_qualified IS NULL AND metadata.source = 'open_graph'
            AND metadata.status IN ('fresh', 'stale')
            AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
              metadata.site_name, metadata.author_name, metadata.published_at::text,
              metadata.icon_url) >= 2
        ) metadata ON metadata.canonical_key = i.canonical_key
      WHERE i.eligible = TRUE AND i.expires_at > $1
        AND i.target_kind IN ('external_article', 'standard_site_document')
        AND i.commercial_class <> 'probable_ad'
        AND i.language_code <> 'und'
        AND i.source_confidence >= $5
        AND COALESCE(i.published_at, i.first_seen_at) >= $2
        AND (
          i.provenance ? 'standard_site'
          OR (metadata.stale_until > $1)
        )
        AND (
          (CASE WHEN $4 THEN r.shares_24h ELSE r.baseline_shares_24h END)
            >= $6
          OR (CASE WHEN $4 THEN r.recommendations_24h
                   ELSE r.baseline_recommendations_24h END)
            >= $7
          OR ((i.provenance ? 'standard_site')
            AND COALESCE(i.published_at, i.first_seen_at) >= $3
            AND i.source_confidence >= $8
            AND (CASE WHEN $4 THEN r.shares_24h
                      ELSE r.baseline_shares_24h END)
              >= $9)
        )
        AND NOT EXISTS (
          SELECT 1 FROM wire_labels l
          WHERE l.canonical_key = i.canonical_key AND l.expires_at > $1
            AND l.label_key IN ('moderation', 'visibility')
            AND l.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
        )
      GROUP BY i.language_code
      HAVING COUNT(*) >= $10
      ORDER BY COUNT(*) DESC, i.language_code
      LIMIT $11
      `
