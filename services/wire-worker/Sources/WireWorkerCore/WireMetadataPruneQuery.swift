import Foundation
import PostgresNIO

enum WireMetadataPruneQuery {
  static let pageSize: Int64 = 100

  static func make(asOf: Date, position: WireMetadataPruneCursor.Position?) -> PostgresQuery {
    var query = PostgresQuery.StringInterpolation(literalCapacity: 2_400, interpolationCount: 8)
    query.appendLiteral("""
      WITH candidates AS MATERIALIZED (
        SELECT canonical_key, stale_until FROM wire_link_metadata_cache
        WHERE stale_until IS NOT NULL AND stale_until <=
      """)
    query.appendLiteral(" ")
    query.appendInterpolation(asOf)
    if let position {
      query.appendLiteral(" AND (stale_until, canonical_key) > (")
      query.appendInterpolation(position.staleUntil)
      query.appendLiteral("::timestamptz, ")
      query.appendInterpolation(position.canonicalKey)
      query.appendLiteral(")")
    }
    // Do not lock while selecting candidates: SKIP LOCKED below LIMIT could inspect an
    // unbounded locked prefix. The raw indexed page bounds both locking and protection work.
    query.appendLiteral("""

        ORDER BY stale_until, canonical_key LIMIT
      """)
    query.appendLiteral(" ")
    query.appendInterpolation(pageSize)
    query.appendLiteral("""

      ), deletable AS MATERIALIZED (
        SELECT cache.canonical_key FROM candidates candidate
        JOIN wire_link_metadata_cache cache ON cache.canonical_key = candidate.canonical_key
        LEFT JOIN LATERAL (
          SELECT true AS protected FROM wire_items item
          WHERE item.canonical_key = cache.canonical_key AND item.eligible
            AND item.expires_at >
      """)
    query.appendLiteral(" ")
    query.appendInterpolation(asOf)
    query.appendLiteral("""

            AND item.canonical_url LIKE 'https://%'
          LIMIT 1 OFFSET 0
        ) live ON true
        WHERE cache.stale_until IS NOT NULL AND cache.stale_until <=
      """)
    query.appendLiteral(" ")
    query.appendInterpolation(asOf)
    query.appendLiteral(" AND NOT (cache.status = 'fetching' AND cache.retry_after > ")
    query.appendInterpolation(asOf)
    query.appendLiteral("""
      ) AND live.protected IS NULL
        FOR UPDATE OF cache SKIP LOCKED
      ), deleted AS (
        DELETE FROM wire_link_metadata_cache cache USING deletable
        WHERE cache.canonical_key = deletable.canonical_key
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM candidates), last.stale_until::text, last.canonical_key,
             (SELECT count(*) FROM deleted)
      FROM (SELECT 1) singleton
      LEFT JOIN LATERAL (
        SELECT stale_until, canonical_key FROM candidates
        ORDER BY stale_until DESC, canonical_key DESC LIMIT 1
      ) last ON true
      """)
    return PostgresQuery(stringInterpolation: query)
  }
}
