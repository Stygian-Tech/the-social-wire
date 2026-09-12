import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  func recordDatabaseObservabilityCounters(at: Date) async throws {
    let rows = try await databaseCostRows(
      """
      SELECT numbackends::bigint, current_setting('max_connections')::bigint,
        (xact_commit + xact_rollback)::bigint,
        CASE WHEN (blks_hit + blks_read) = 0 THEN NULL::double precision
          ELSE blks_hit::double precision / (blks_hit + blks_read)::double precision END,
        stats_reset,
        (SELECT COUNT(*)::bigint FROM pg_stat_activity
          WHERE datname = current_database() AND state = 'active' AND pid <> pg_backend_pid())
      FROM pg_stat_database WHERE datname = current_database()
      """)
    for row in rows {
      let value = try row.decode((Int64, Int64, Int64, Double?, Date?, Int64).self)
      databaseObservabilitySamples.record(.init(
        connections: value.0, maxConnections: value.1, transactions: value.2,
        cacheHitRatio: value.3, statsResetAt: value.4, activeQueries: value.5, observedAt: at))
    }
  }

  func recordDatabaseObservabilityTables(at: Date) async throws {
    let rows = try await databaseCostRows(
      """
      SELECT pg_database_size(current_database())::bigint,
        COALESCE(SUM(n_live_tup), 0)::bigint FROM pg_stat_user_tables
      """)
    guard let row = rows.first else { return }
    let value = try row.decode((Int64, Int64).self)
    guard !Task.isCancelled else { return }
    let tableRows = try await databaseCostRows(
      """
      SELECT schemaname, relname, n_live_tup::bigint FROM pg_stat_user_tables
      ORDER BY n_live_tup DESC, schemaname, relname LIMIT 10
      """)
    let tables = try tableRows.map { row in
      let table = try row.decode((String, String, Int64).self)
      return DatabaseTableRecordCount(schema: table.0, table: table.1, estimatedRecords: table.2)
    }
    databaseObservabilitySamples.record(.init(
      databaseSizeBytes: value.0, estimatedRecords: value.1, topTables: tables, observedAt: at))
  }
}
