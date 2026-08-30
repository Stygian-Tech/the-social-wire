import Foundation
import Logging
import PostgresNIO

struct PostgresWireBaselineLabelStore: WireBaselineLabelStore {
  let pool: PostgresClient
  let logger: Logger

  func loadTargets(limit: Int, asOf: Date) async throws -> [WireBaselineLabelTarget] {
    let rows = try await pool.query(
      """
      SELECT item.canonical_key, item.representative_uri, item.author_key
      FROM wire_items item
      JOIN wire_signal_rollups rollup ON rollup.canonical_key = item.canonical_key
      WHERE item.eligible = TRUE AND item.expires_at > \(asOf)
        AND item.source_confidence >= 0.25
        AND (item.representative_uri IS NOT NULL OR item.author_key IS NOT NULL)
        AND (rollup.shares_24h >= 3 OR rollup.recommendations_24h >= 1)
      ORDER BY rollup.shares_24h DESC, rollup.recommendations_24h DESC,
               item.canonical_key
      LIMIT \(max(1, min(limit, 10_000)))
      """,
      logger: logger
    )
    var targets: [WireBaselineLabelTarget] = []
    for try await row in rows {
      let value = try row.decode((String, String?, String?).self)
      targets.append(
        WireBaselineLabelTarget(
          canonicalKey: value.0,
          representativeURI: value.1,
          authorDID: value.2
        )
      )
    }
    return targets
  }

  func replaceSnapshot(
    labels: [WireBaselineLabel],
    labelers: [WireLabelerEndpoint],
    refreshedCanonicalKeys: [String],
    targetCount: Int,
    refreshedAt: Date
  ) async throws {
    let canonicalKeysJSON = String(
      decoding: try JSONEncoder().encode(refreshedCanonicalKeys),
      as: UTF8.self
    )
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "UPDATE wire_label_refresh_state SET is_current = FALSE WHERE is_current = TRUE",
        logger: logger
      )
      for labeler in labelers {
        let sourcePrefix = "\(labeler.sourceDID)|"
        try await connection.query(
          """
          DELETE FROM wire_labels
          WHERE LEFT(source, char_length(\(sourcePrefix))) = \(sourcePrefix)
            AND canonical_key IN (
              SELECT value FROM jsonb_array_elements_text(\(canonicalKeysJSON)::jsonb)
            )
          """,
          logger: logger
        )
      }
      for label in labels {
        try await connection.query(
          """
          INSERT INTO wire_labels
            (canonical_key, label_key, label_value, source, confidence, applied_at, expires_at)
          VALUES
            (\(label.canonicalKey), \(label.labelKey), \(label.labelValue), \(label.source),
             1, \(label.appliedAt), \(label.expiresAt))
          ON CONFLICT (canonical_key, label_key, source) DO UPDATE SET
            label_value = EXCLUDED.label_value,
            confidence = EXCLUDED.confidence,
            applied_at = EXCLUDED.applied_at,
            expires_at = EXCLUDED.expires_at
          """,
          logger: logger
        )
      }
      for labeler in labelers {
        let labelCount = labels.lazy.filter { $0.source.hasPrefix("\(labeler.sourceDID)|") }.count
        try await connection.query(
          """
          INSERT INTO wire_label_refresh_state
            (source_did, endpoint_host, last_attempted_at, last_successful_at,
             target_count, label_count, is_current)
          VALUES
            (\(labeler.sourceDID), \(labeler.endpointHost), \(refreshedAt), \(refreshedAt),
             \(targetCount), \(labelCount), TRUE)
          ON CONFLICT (source_did) DO UPDATE SET
            endpoint_host = EXCLUDED.endpoint_host,
            last_attempted_at = EXCLUDED.last_attempted_at,
            last_successful_at = EXCLUDED.last_successful_at,
            target_count = EXCLUDED.target_count,
            label_count = EXCLUDED.label_count,
            is_current = TRUE
          """,
          logger: logger
        )
      }
    }
  }

  func verifyFresh(
    labelers: [WireLabelerEndpoint],
    asOf: Date,
    maximumAge: TimeInterval
  ) async throws {
    let minimumSuccess = asOf.addingTimeInterval(-maximumAge)
    for labeler in labelers {
      let rows = try await pool.query(
        """
        SELECT 1
        FROM wire_label_refresh_state
        WHERE source_did = \(labeler.sourceDID)
          AND is_current = TRUE
          AND endpoint_host = \(labeler.endpointHost)
          AND last_successful_at >= \(minimumSuccess)
        LIMIT 1
        """,
        logger: logger
      )
      var found = false
      for try await _ in rows { found = true }
      guard found else { throw WireLabelQueryError.staleRefresh }
    }
  }
}
