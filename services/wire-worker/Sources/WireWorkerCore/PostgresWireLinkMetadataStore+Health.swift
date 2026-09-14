import Foundation
import PostgresNIO

extension PostgresWireLinkMetadataStore {
  // Logging-only corpus diagnostics run independently of enrichment. A slow scan
  // abandons this sample; it must never hold the fetch loop or retry immediately.
  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot? {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SET TRANSACTION READ ONLY", logger: logger)
      try await connection.query("SET LOCAL statement_timeout = '2s'", logger: logger)
      try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: logger)
      let rows = try await connection.query(
        """
        WITH metadata AS (
          SELECT
            COUNT(*) FILTER (WHERE status = 'fresh' AND fresh_until > \(asOf))::bigint AS hits,
            COUNT(*) FILTER (WHERE fresh_until <= \(asOf) AND stale_until > \(asOf))::bigint AS stale,
            COUNT(*) FILTER (WHERE status IN ('pending', 'fetching', 'retry', 'negative'))::bigint AS misses,
            COUNT(*) FILTER (WHERE status IN ('retry', 'negative', 'failed'))::bigint AS failures,
            COALESCE(EXTRACT(EPOCH FROM (\(asOf) - MIN(updated_at) FILTER (
              WHERE status IN ('retry', 'negative', 'failed')))), 0)::double precision AS failure_age
          FROM wire_link_metadata_cache
        ), eligible_people AS (
          SELECT COUNT(*)::bigint AS count FROM (
            SELECT subject_did FROM wire_item_mentions
            WHERE expires_at > \(asOf)
            GROUP BY subject_did
            HAVING COUNT(DISTINCT canonical_key) >= 2
               AND COUNT(DISTINCT speaker_key_hash) >= 3
          ) eligible
        ), fresh_people AS (
          SELECT COUNT(*)::bigint AS count FROM wire_talked_accounts
          WHERE status = 'fresh' AND expires_at > \(asOf)
        )
        SELECT metadata.hits, metadata.stale, metadata.misses, metadata.failures,
               metadata.failure_age, eligible_people.count, fresh_people.count
        FROM metadata, eligible_people, fresh_people
        """,
        logger: logger
      )
      for try await row in rows {
        let value = try row.decode((Int64, Int64, Int64, Int64, Double, Int64, Int64).self)
        return WireEnrichmentHealthSnapshot(
          metadataHitCount: Int(value.0), metadataStaleCount: Int(value.1),
          metadataMissCount: Int(value.2), metadataFailureCount: Int(value.3),
          oldestFailureAgeSeconds: value.4, peopleEligibleCount: Int(value.5),
          peopleFreshCount: Int(value.6)
        )
      }
      return nil
    }
  }
}
