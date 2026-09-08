import Foundation
import PostgresNIO

extension PostgresWireLinkMetadataStore {
  /// Item writes seed new work atomically. This sweep only repairs historical
  /// holes and missing cache rows after recovery, without scanning the corpus
  /// to discover that nothing is missing. It is safe for multiple workers.
  func repairMissingMetadata(asOf: Date, pageSize: Int = 1_000) async throws {
    try await pool.query(Self.metadataRepairQuery(asOf: asOf, pageSize: pageSize), logger: logger)
  }

  static func metadataRepairQuery(asOf: Date, pageSize: Int) -> PostgresQuery {
    let boundedPageSize = max(1, min(pageSize, 1_000))
    return """
      WITH cursor AS MATERIALIZED (
        SELECT canonical_key FROM wire_metadata_repair_cursor
        WHERE singleton LIMIT 1 FOR UPDATE SKIP LOCKED
      ), candidates AS MATERIALIZED (
        SELECT item.* FROM cursor
        CROSS JOIN LATERAL (
          SELECT canonical_key, canonical_url, eligible, expires_at
          FROM wire_items
          WHERE canonical_key > cursor.canonical_key
          ORDER BY canonical_key
          LIMIT \(boundedPageSize)
        ) item
      ), seeded AS (
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, source, status, retry_after, failure_count, updated_at)
        SELECT item.canonical_key, item.canonical_url, 'fallback', 'pending', \(asOf), 0, \(asOf)
        FROM candidates item
        LEFT JOIN LATERAL (
          SELECT canonical_key FROM wire_link_metadata_cache
          WHERE canonical_key = item.canonical_key LIMIT 1
        ) existing ON TRUE
        WHERE item.eligible AND item.expires_at > \(asOf)
          AND item.canonical_url LIKE 'https://%' AND existing.canonical_key IS NULL
        ON CONFLICT (canonical_key) DO NOTHING
        RETURNING canonical_key
      )
      UPDATE wire_metadata_repair_cursor
      SET canonical_key = CASE WHEN (SELECT COUNT(*) FROM candidates) < \(boundedPageSize)
          THEN '' ELSE (SELECT MAX(canonical_key) FROM candidates) END,
        updated_at = \(asOf)
      WHERE singleton AND EXISTS (SELECT 1 FROM cursor)
      """
  }
}
