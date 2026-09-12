import Foundation
import PostgresNIO

extension PostgresWireLinkMetadataStore {
  func metadataSchedulingReady() async throws -> Bool {
    let rows = try await pool.query("""
      SELECT tracking_enabled AND read_ready
        AND validated_postmaster_started_at IS NOT DISTINCT FROM pg_postmaster_start_time() AND
        EXISTS (SELECT 1 FROM pg_index
          WHERE indexrelid = to_regclass('wire_metadata_priority_work_order_idx') AND indisvalid AND indisready) AND
        (SELECT COUNT(*) = 2 FROM pg_trigger
         WHERE tgname IN ('wire_metadata_schedule_item_sync', 'wire_metadata_schedule_cache_sync')
           AND tgrelid IN ('wire_items'::regclass, 'wire_link_metadata_cache'::regclass)
           AND tgenabled IN ('O', 'A') AND tgdeferrable AND tginitdeferred)
      FROM wire_metadata_schedule_control WHERE singleton
      """, logger: logger)
    for try await row in rows { return try row.decode(Bool.self) }
    return false
  }

  func backfillMetadataScheduling(pageSize: Int = 500) async throws {
    try await pool.query("SELECT wire_metadata_schedule_reset_after_restart()", logger: logger)
    let limit = max(1, min(pageSize, 500))
    // Each pass commits before locking the other source. Never acquire a base
    // cache lock while holding projection locks from the item pass (or vice versa).
    for query in [Self.metadataSchedulingItemBackfill(limit: limit), Self.metadataSchedulingCacheBackfill(limit: limit)] {
      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: logger)
        try await connection.query("SET LOCAL statement_timeout = '5s'", logger: logger)
        try await connection.query(query, logger: logger)
      }
    }
  }

  /// Validate one consistent snapshot. A failed pass wraps both cursors so skipped
  /// locked source rows are revisited; the old reader remains available throughout.
  @discardableResult
  func validateMetadataSchedulingIfComplete(asOf: Date) async throws -> Int64? {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", logger: logger)
      try await connection.query("SET LOCAL statement_timeout = '30s'", logger: logger)
      let controls = try await connection.query("""
        SELECT singleton FROM wire_metadata_schedule_control
        WHERE singleton AND tracking_enabled AND NOT read_ready
          AND tracking_postmaster_started_at = pg_postmaster_start_time()
          AND item_pass_complete AND cache_pass_complete FOR UPDATE SKIP LOCKED
        """, logger: logger)
      var shouldValidate = false
      for try await _ in controls { shouldValidate = true }
      guard shouldValidate else { return nil }
      let rows = try await connection.query(Self.metadataSchedulingParityQuery, logger: logger)
      var mismatches: Int64 = 0
      for try await row in rows { mismatches = try row.decode(Int64.self) }
      try await connection.query("""
        UPDATE wire_metadata_schedule_control
        SET read_ready = \(mismatches == 0), validated_postmaster_started_at = pg_postmaster_start_time(), validated_at = \(asOf), validation_mismatches = \(mismatches),
            item_cursor = '', cache_cursor = '',
            item_pass_complete = \(mismatches == 0), cache_pass_complete = \(mismatches == 0)
        WHERE singleton
        """, logger: logger)
      return mismatches
    }
  }

  func cleanupMetadataScheduling(pageSize: Int = 500) async throws {
    let limit = max(1, min(pageSize, 500))
    try await pool.query("""
      WITH expired AS (
        SELECT canonical_key FROM wire_metadata_priority_work
        WHERE NOT item_present AND NOT cache_present ORDER BY canonical_key
        LIMIT \(limit) FOR UPDATE SKIP LOCKED
      )
      DELETE FROM wire_metadata_priority_work schedule USING expired
      WHERE schedule.canonical_key = expired.canonical_key
        AND NOT schedule.item_present AND NOT schedule.cache_present
      """, logger: logger)
  }

  static func metadataSchedulingItemBackfill(limit: Int) -> PostgresQuery {
    """
    WITH control AS MATERIALIZED (
      SELECT item_cursor FROM wire_metadata_schedule_control
      WHERE singleton AND tracking_enabled AND tracking_postmaster_started_at = pg_postmaster_start_time()
        AND NOT read_ready AND NOT item_pass_complete
      FOR UPDATE SKIP LOCKED
    ), candidates AS MATERIALIZED (
      SELECT source.* FROM control CROSS JOIN LATERAL (
        SELECT canonical_key, language_code, eligible, expires_at, target_kind, commercial_class, source_confidence, last_signal_at FROM wire_items
        WHERE canonical_key > control.item_cursor ORDER BY canonical_key
        LIMIT \(limit) FOR UPDATE SKIP LOCKED
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
        item_pass_complete = (SELECT COUNT(*) FROM candidates) < \(limit)
    WHERE singleton AND EXISTS (SELECT 1 FROM control)
    """
  }

  static func metadataSchedulingCacheBackfill(limit: Int) -> PostgresQuery {
    """
    WITH control AS MATERIALIZED (
      SELECT cache_cursor FROM wire_metadata_schedule_control
      WHERE singleton AND tracking_enabled AND tracking_postmaster_started_at = pg_postmaster_start_time()
        AND NOT read_ready AND NOT cache_pass_complete
      FOR UPDATE SKIP LOCKED
    ), candidates AS MATERIALIZED (
      SELECT source.* FROM control CROSS JOIN LATERAL (
        SELECT canonical_key, language_checked_at, source, status, retry_after, fresh_until FROM wire_link_metadata_cache
        WHERE canonical_key > control.cache_cursor ORDER BY canonical_key
        LIMIT \(limit) FOR UPDATE SKIP LOCKED
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
        cache_pass_complete = (SELECT COUNT(*) FROM candidates) < \(limit)
    WHERE singleton AND EXISTS (SELECT 1 FROM control)
    """
  }

  static var metadataSchedulingParityQuery: PostgresQuery {
    """
    SELECT (
      SELECT COUNT(*) FROM wire_items source FULL JOIN wire_metadata_priority_work schedule USING (canonical_key)
      WHERE COALESCE(schedule.item_present, false) IS DISTINCT FROM (source.canonical_key IS NOT NULL)
        OR (source.canonical_key IS NOT NULL AND ROW(source.language_code, source.eligible, source.expires_at, source.target_kind, source.commercial_class, source.source_confidence, source.last_signal_at)
          IS DISTINCT FROM ROW(schedule.language_code, schedule.eligible, schedule.expires_at, schedule.target_kind, schedule.commercial_class, schedule.source_confidence, schedule.last_signal_at))
    ) + (
      SELECT COUNT(*) FROM wire_link_metadata_cache source FULL JOIN wire_metadata_priority_work schedule USING (canonical_key)
      WHERE COALESCE(schedule.cache_present, false) IS DISTINCT FROM (source.canonical_key IS NOT NULL)
        OR (source.canonical_key IS NOT NULL AND ROW(source.language_checked_at, source.source, source.status, source.retry_after, source.fresh_until)
          IS DISTINCT FROM ROW(schedule.language_checked_at, schedule.source, schedule.status, schedule.retry_after, schedule.fresh_until))
    ) AS mismatches
    """
  }
}
