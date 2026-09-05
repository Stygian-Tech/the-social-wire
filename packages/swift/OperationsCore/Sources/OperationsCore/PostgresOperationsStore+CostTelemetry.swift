import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  /// Bounded catalog and indexed expiry samples; never expose query text or private row identifiers.
  public func recordDatabaseCostTelemetry(at: Date) async {
    guard !Task.isCancelled else { return }
    guard !isDatabaseCostObservationRunning else { return }
    if let last = lastDatabaseCostObservation, at.timeIntervalSince(last) < 60 { return }
    isDatabaseCostObservationRunning = true
    defer { isDatabaseCostObservationRunning = false }
    lastDatabaseCostObservation = at
    var samples: [OperationsTelemetrySignal] = []
    func metric(_ name: String, _ value: Double, table: String? = nil) {
      var dimensions = ["environment": environment, "service": "postgres"]
      if let table { dimensions["table"] = table }
      samples.append(
        .metric(
          .init(
            name: "socialwire.database.\(name)", value: value, dimensions: dimensions,
            recordedAt: at)))
    }
    do {
      let rows = try await databaseCostRows(
        """
        SELECT w.wal_bytes::double precision, w.wal_fpi::double precision,
          c.num_requested::double precision, c.num_timed::double precision,
          a.failed_count::double precision, d.temp_bytes::double precision,
          EXTRACT(EPOCH FROM w.stats_reset)::double precision
        FROM pg_stat_wal w CROSS JOIN pg_stat_checkpointer c
          CROSS JOIN pg_stat_archiver a CROSS JOIN pg_stat_database d
        WHERE d.datname = current_database()
        """)
      for row in rows {
        let v = try row.decode((Double, Double, Double, Double, Double, Double, Double).self)
        metric("wal_bytes_total", v.0)
        metric("wal_full_page_images_total", v.1)
        metric("checkpoints_requested_total", v.2)
        metric("checkpoints_timed_total", v.3)
        metric("archive_failures_total", v.4)
        metric("temporary_bytes_total", v.5)
        if let previous = lastDatabaseWALObservation,
          previous.reset == v.6, v.0 >= previous.bytes, at > previous.at
        {
          metric("wal_bytes_per_second", (v.0 - previous.bytes) / at.timeIntervalSince(previous.at))
        }
        lastDatabaseWALObservation = (v.0, v.6, at)
      }
      guard !Task.isCancelled else { return }
      let tables = try await databaseCostRows(
        """
        SELECT relname, pg_total_relation_size(relid)::double precision,
          n_dead_tup::double precision, n_tup_upd::double precision,
          n_tup_hot_upd::double precision
        FROM pg_stat_user_tables
        WHERE schemaname = 'public' AND relname IN (
          'wire_ranked_items', 'wire_items', 'wire_item_aliases', 'wire_link_metadata_cache',
          'wire_ingestion_inbox', 'appview_ingestion_inbox', 'content_items',
          'operations_change_events', 'operations_metric_rollups', 'wire_edition_module_items')
        ORDER BY relname
        """)
      for row in tables {
        let v = try row.decode((String, Double, Double, Double, Double).self)
        metric("table_bytes", v.1, table: v.0)
        metric("dead_rows_estimated", v.2, table: v.0)
        metric("updates_total", v.3, table: v.0)
        metric("hot_updates_total", v.4, table: v.0)
      }
    } catch {
      // Older PG versions and restricted roles may omit these counters. Database
      // readiness remains independently checked, and later samples can recover.
      logger.debug("Database cost counters unavailable")
    }
    guard !Task.isCancelled else { return }
    do {
      let rows = try await databaseCostRows(
        """
        SELECT COALESCE(SUM(total_exec_time), 0)::double precision,
          COALESCE(SUM(wal_bytes), 0)::double precision,
          COALESCE(SUM(temp_blks_written), 0)::double precision
        FROM pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        """)
      for row in rows {
        let v = try row.decode((Double, Double, Double).self)
        metric("statement_execution_ms_total", v.0)
        metric("statement_wal_bytes_total", v.1)
        metric("statement_temp_blocks_written_total", v.2)
      }
    } catch {
      logger.debug("Statement cost counters unavailable; check extension and preload")
    }
    guard !Task.isCancelled else { return }
    do {
      for row in try await databaseExpiryBacklogRows(at: at) {
        let value = try row.decode((String, Int64, Bool).self)
        metric("expired_rows_lower_bound", Double(min(value.1, 1_000)), table: value.0)
        metric("expired_rows_truncated", value.2 ? 1 : 0, table: value.0)
      }
    } catch {
      logger.debug("Expiry backlog sample unavailable")
    }
    guard !Task.isCancelled else { return }
    do {
      for row in try await databaseGenerationDurationRows() {
        let value = try row.decode((String, String?).self)
        guard let raw = value.1, let milliseconds = Double(raw),
          milliseconds.isFinite, milliseconds >= 0
        else { continue }
        samples.append(
          .metric(
            .init(
              name: "socialwire.wire.generation_duration_ms", value: milliseconds,
              dimensions: [
                "environment": environment, "service": "wire-worker", "language": value.0,
              ],
              recordedAt: at)))
      }
    } catch {
      logger.debug("Generation duration sample unavailable")
    }
    guard !Task.isCancelled else { return }
    do { try await recordTelemetryBatch(samples, statementTimeoutMilliseconds: 2_000) } catch {
      logger.debug("Database cost telemetry export unavailable")
    }
  }

  /// A stalled catalog/statistics query must not indefinitely delay the collector. The local
  /// setting rolls back with this transaction and never changes another caller's pooled session.
  func databaseCostRows(_ query: PostgresQuery) async throws -> [PostgresRow] {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SET LOCAL statement_timeout = '2s'", logger: logger)
      let rows = try await connection.query(query, logger: logger)
      var result: [PostgresRow] = []
      for try await row in rows { result.append(row) }
      return result
    }
  }
}
