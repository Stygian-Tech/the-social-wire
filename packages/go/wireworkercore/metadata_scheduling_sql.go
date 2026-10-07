package wireworkercore

const metadataSchedulingReadySQL = `SELECT tracking_enabled AND read_ready
        AND validated_postmaster_started_at IS NOT DISTINCT FROM pg_postmaster_start_time() AND
        EXISTS (SELECT 1 FROM pg_index
          WHERE indexrelid = to_regclass('wire_metadata_priority_work_order_idx') AND indisvalid AND indisready) AND
        (SELECT COUNT(*) = 2 FROM pg_trigger
         WHERE tgname IN ('wire_metadata_schedule_item_sync', 'wire_metadata_schedule_cache_sync')
           AND tgrelid IN ('wire_items'::regclass, 'wire_link_metadata_cache'::regclass)
           AND tgenabled IN ('O', 'A') AND tgdeferrable AND tginitdeferred)
      FROM wire_metadata_schedule_control WHERE singleton`

const metadataSchedulingControlSQL = `SELECT singleton FROM wire_metadata_schedule_control
        WHERE singleton AND tracking_enabled AND NOT read_ready
          AND tracking_postmaster_started_at = pg_postmaster_start_time()
          AND item_pass_complete AND cache_pass_complete FOR UPDATE SKIP LOCKED`

const metadataSchedulingValidateSQL = `UPDATE wire_metadata_schedule_control
        SET read_ready = $1, validated_postmaster_started_at = pg_postmaster_start_time(), validated_at = $2, validation_mismatches = $3,
            item_cursor = '', cache_cursor = '',
            item_pass_complete = $1, cache_pass_complete = $1
        WHERE singleton`

const metadataSchedulingCleanupSQL = `WITH expired AS (
        SELECT canonical_key FROM wire_metadata_priority_work
        WHERE NOT item_present AND NOT cache_present ORDER BY canonical_key
        LIMIT $1 FOR UPDATE SKIP LOCKED
      )
      DELETE FROM wire_metadata_priority_work schedule USING expired
      WHERE schedule.canonical_key = expired.canonical_key
        AND NOT schedule.item_present AND NOT schedule.cache_present`

const metadataSchedulingItemBackfillSQL = `WITH control AS MATERIALIZED (
      SELECT item_cursor FROM wire_metadata_schedule_control
      WHERE singleton AND tracking_enabled AND tracking_postmaster_started_at = pg_postmaster_start_time()
        AND NOT read_ready AND NOT item_pass_complete
      FOR UPDATE SKIP LOCKED
    ), candidates AS MATERIALIZED (
      SELECT source.* FROM control CROSS JOIN LATERAL (
        SELECT canonical_key, language_code, eligible, expires_at, target_kind, commercial_class, source_confidence, last_signal_at FROM wire_items
        WHERE canonical_key > control.item_cursor ORDER BY canonical_key
        LIMIT $1 FOR UPDATE SKIP LOCKED
      ) source
    ), copied AS (
      INSERT INTO wire_metadata_priority_work (canonical_key, item_present, language_code, eligible, expires_at, target_kind, commercial_class, source_confidence, last_signal_at)
      SELECT canonical_key, true, language_code, eligible, expires_at, target_kind, commercial_class, source_confidence, last_signal_at FROM candidates ORDER BY canonical_key
      ON CONFLICT (canonical_key) DO UPDATE SET
        item_present = EXCLUDED.item_present, language_code = EXCLUDED.language_code, eligible = EXCLUDED.eligible, expires_at = EXCLUDED.expires_at, target_kind = EXCLUDED.target_kind, commercial_class = EXCLUDED.commercial_class, source_confidence = EXCLUDED.source_confidence, last_signal_at = EXCLUDED.last_signal_at
      WHERE ROW(wire_metadata_priority_work.item_present, wire_metadata_priority_work.language_code, wire_metadata_priority_work.eligible, wire_metadata_priority_work.expires_at, wire_metadata_priority_work.target_kind, wire_metadata_priority_work.commercial_class, wire_metadata_priority_work.source_confidence, wire_metadata_priority_work.last_signal_at)
        IS DISTINCT FROM ROW(EXCLUDED.item_present, EXCLUDED.language_code, EXCLUDED.eligible, EXCLUDED.expires_at, EXCLUDED.target_kind, EXCLUDED.commercial_class, EXCLUDED.source_confidence, EXCLUDED.last_signal_at)
      RETURNING canonical_key
    )
    UPDATE wire_metadata_schedule_control
    SET item_cursor = COALESCE((SELECT MAX(canonical_key) FROM candidates), ''),
        item_pass_complete = (SELECT COUNT(*) FROM candidates) < $1
    WHERE singleton AND EXISTS (SELECT 1 FROM control)`

const metadataSchedulingCacheBackfillSQL = `WITH control AS MATERIALIZED (
      SELECT cache_cursor FROM wire_metadata_schedule_control
      WHERE singleton AND tracking_enabled AND tracking_postmaster_started_at = pg_postmaster_start_time()
        AND NOT read_ready AND NOT cache_pass_complete
      FOR UPDATE SKIP LOCKED
    ), candidates AS MATERIALIZED (
      SELECT source.* FROM control CROSS JOIN LATERAL (
        SELECT canonical_key, language_checked_at, source, status, retry_after, fresh_until FROM wire_link_metadata_cache
        WHERE canonical_key > control.cache_cursor ORDER BY canonical_key
        LIMIT $1 FOR UPDATE SKIP LOCKED
      ) source
    ), copied AS (
      INSERT INTO wire_metadata_priority_work (canonical_key, cache_present, language_checked_at, source, status, retry_after, fresh_until)
      SELECT canonical_key, true, language_checked_at, source, status, retry_after, fresh_until FROM candidates ORDER BY canonical_key
      ON CONFLICT (canonical_key) DO UPDATE SET
        cache_present = EXCLUDED.cache_present, language_checked_at = EXCLUDED.language_checked_at, source = EXCLUDED.source, status = EXCLUDED.status, retry_after = EXCLUDED.retry_after, fresh_until = EXCLUDED.fresh_until
      WHERE ROW(wire_metadata_priority_work.cache_present, wire_metadata_priority_work.language_checked_at, wire_metadata_priority_work.source, wire_metadata_priority_work.status, wire_metadata_priority_work.retry_after, wire_metadata_priority_work.fresh_until)
        IS DISTINCT FROM ROW(EXCLUDED.cache_present, EXCLUDED.language_checked_at, EXCLUDED.source, EXCLUDED.status, EXCLUDED.retry_after, EXCLUDED.fresh_until)
      RETURNING canonical_key
    )
    UPDATE wire_metadata_schedule_control
    SET cache_cursor = COALESCE((SELECT MAX(canonical_key) FROM candidates), ''),
        cache_pass_complete = (SELECT COUNT(*) FROM candidates) < $1
    WHERE singleton AND EXISTS (SELECT 1 FROM control)`

const metadataSchedulingParitySQL = `SELECT (
      SELECT COUNT(*) FROM wire_items source FULL JOIN wire_metadata_priority_work schedule USING (canonical_key)
      WHERE COALESCE(schedule.item_present, false) IS DISTINCT FROM (source.canonical_key IS NOT NULL)
        OR (source.canonical_key IS NOT NULL AND ROW(source.language_code, source.eligible, source.expires_at, source.target_kind, source.commercial_class, source.source_confidence, source.last_signal_at)
          IS DISTINCT FROM ROW(schedule.language_code, schedule.eligible, schedule.expires_at, schedule.target_kind, schedule.commercial_class, schedule.source_confidence, schedule.last_signal_at))
    ) + (
      SELECT COUNT(*) FROM wire_link_metadata_cache source FULL JOIN wire_metadata_priority_work schedule USING (canonical_key)
      WHERE COALESCE(schedule.cache_present, false) IS DISTINCT FROM (source.canonical_key IS NOT NULL)
        OR (source.canonical_key IS NOT NULL AND ROW(source.language_checked_at, source.source, source.status, source.retry_after, source.fresh_until)
          IS DISTINCT FROM ROW(schedule.language_checked_at, schedule.source, schedule.status, schedule.retry_after, schedule.fresh_until))
    ) AS mismatches`

const metadataScheduledPrioritySQL = `WITH due AS (
          SELECT cache.canonical_key
          FROM wire_metadata_priority_work item
          JOIN wire_link_metadata_cache cache ON cache.canonical_key = item.canonical_key
          WHERE item.item_present AND item.cache_present
            AND EXISTS (
              SELECT 1 FROM wire_items authoritative
              WHERE authoritative.canonical_key = item.canonical_key
                AND authoritative.language_code = 'und' AND authoritative.eligible
                AND authoritative.expires_at > $1
                AND authoritative.target_kind IN ('external_article', 'standard_site_document')
                AND authoritative.commercial_class <> 'probable_ad'
                AND authoritative.source_confidence >= 0.25
            )
            AND item.language_code = 'und'
            AND item.eligible = TRUE AND item.expires_at > $1
            AND item.target_kind IN ('external_article', 'standard_site_document')
            AND item.commercial_class <> 'probable_ad'
            AND item.source_confidence >= 0.25
            AND item.language_checked_at IS NULL AND cache.language_checked_at IS NULL
            AND cache.status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND (
              (cache.retry_after <= $1
                AND (cache.fresh_until IS NULL OR cache.fresh_until <= $1))
              OR (cache.source = 'open_graph' AND cache.status IN ('fresh', 'stale')
                AND cache.language_checked_at IS NULL)
            )
            AND item.status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching')
            AND ((item.retry_after <= $1 AND (item.fresh_until IS NULL OR item.fresh_until <= $1))
              OR (item.source = 'open_graph' AND item.status IN ('fresh', 'stale')
                AND item.language_checked_at IS NULL))
          ORDER BY item.last_signal_at DESC NULLS LAST, item.retry_after, item.canonical_key
          FOR UPDATE OF cache SKIP LOCKED
          LIMIT $2
        )
        UPDATE wire_link_metadata_cache cache
        SET status = 'fetching', retry_after = $3,
            fresh_until = CASE WHEN cache.language_checked_at IS NULL
              THEN LEAST(COALESCE(cache.fresh_until, $1), $1)
              ELSE cache.fresh_until END,
            updated_at = $1
        FROM due
        WHERE cache.canonical_key = due.canonical_key
        RETURNING cache.canonical_key, cache.canonical_url,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.etag END,
          CASE WHEN cache.language_checked_at IS NULL THEN NULL ELSE cache.last_modified END,
          cache.retry_after`
