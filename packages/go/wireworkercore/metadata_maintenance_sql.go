package wireworkercore

const metadataRepairSQL = `WITH cursor AS MATERIALIZED (
        SELECT canonical_key FROM wire_metadata_repair_cursor
        WHERE singleton LIMIT 1 FOR UPDATE SKIP LOCKED
      ), candidates AS MATERIALIZED (
        SELECT item.* FROM cursor
        CROSS JOIN LATERAL (
          SELECT canonical_key
          FROM wire_items
          WHERE canonical_key > cursor.canonical_key
          ORDER BY canonical_key
          LIMIT $1
        ) item
      ), missing AS MATERIALIZED (
        SELECT candidate.canonical_key FROM candidates candidate
        LEFT JOIN LATERAL (
          SELECT canonical_key FROM wire_link_metadata_cache
          WHERE canonical_key = candidate.canonical_key LIMIT 1
        ) existing ON TRUE
        WHERE existing.canonical_key IS NULL
      ), seeded AS (
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, source, status, retry_after, failure_count, updated_at)
        SELECT item.canonical_key, item.canonical_url, 'fallback', 'pending', $2, 0, $2
        FROM missing
        JOIN wire_items item ON item.canonical_key = missing.canonical_key
        WHERE item.eligible AND item.expires_at > $2
          AND item.canonical_url LIKE 'https://%'
        ON CONFLICT (canonical_key) DO NOTHING
        RETURNING canonical_key
      ), advanced AS (
        UPDATE wire_metadata_repair_cursor
        SET canonical_key = CASE WHEN (SELECT COUNT(*) FROM candidates) < $1
            THEN '' ELSE (SELECT MAX(canonical_key) FROM candidates) END,
          updated_at = $2
        WHERE singleton AND EXISTS (SELECT 1 FROM cursor)
          AND canonical_key IS DISTINCT FROM
            CASE WHEN (SELECT COUNT(*) FROM candidates) < $1
              THEN '' ELSE (SELECT MAX(canonical_key) FROM candidates) END
        RETURNING singleton
      )
      SELECT (SELECT COUNT(*) FROM candidates), (SELECT COUNT(*) FROM seeded),
        EXISTS (SELECT 1 FROM cursor) AND (SELECT COUNT(*) FROM candidates) < $1`

const metadataHealthSQL = `WITH metadata AS (
          SELECT
            COUNT(*) FILTER (WHERE status = 'fresh' AND fresh_until > $1)::bigint AS hits,
            COUNT(*) FILTER (WHERE fresh_until <= $1 AND stale_until > $1)::bigint AS stale,
            COUNT(*) FILTER (WHERE status IN ('pending', 'fetching', 'retry', 'negative'))::bigint AS misses,
            COUNT(*) FILTER (WHERE status IN ('retry', 'negative', 'failed'))::bigint AS failures,
            COALESCE(EXTRACT(EPOCH FROM ($1 - MIN(updated_at) FILTER (
              WHERE status IN ('retry', 'negative', 'failed')))), 0)::double precision AS failure_age
          FROM wire_link_metadata_cache
        ), eligible_people AS (
          SELECT COUNT(*)::bigint AS count FROM (
            SELECT subject_did FROM wire_item_mentions
            WHERE expires_at > $1
            GROUP BY subject_did
            HAVING COUNT(DISTINCT canonical_key) >= 2
               AND COUNT(DISTINCT speaker_key_hash) >= 3
          ) eligible
        ), fresh_people AS (
          SELECT COUNT(*)::bigint AS count FROM wire_talked_accounts
          WHERE status = 'fresh' AND expires_at > $1
        )
        SELECT metadata.hits, metadata.stale, metadata.misses, metadata.failures,
               metadata.failure_age, eligible_people.count, fresh_people.count
        FROM metadata, eligible_people, fresh_people`
