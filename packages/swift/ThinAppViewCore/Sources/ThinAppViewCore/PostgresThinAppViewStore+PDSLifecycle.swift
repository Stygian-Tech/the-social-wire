import Foundation
import PostgresNIO

extension PostgresThinAppViewStore: PDSReadStateLifecycleStoring {
  public func touchPDSReadStateAccess(viewerDid: String, at: Date) async throws {
    try await pool.query(
      """
      UPDATE appview_pds_read_state_authority SET last_accessed_at = \(at)
      WHERE viewer_did = \(viewerDid) AND manifest_cid IS NOT NULL
        AND last_accessed_at <= \(at.addingTimeInterval(-3600))
      """, logger: logger)
  }

  public func evictIdlePDSReadState(before: Date, at: Date, batchSize: Int) async throws -> PDSReadStateEvictionBatch {
    let limit = max(1, min(batchSize, 1_000))
    return try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SET LOCAL statement_timeout = '5s'", logger: logger)
      let candidates = try await connection.query(
        """
        SELECT authority.viewer_did, authority.projection_ready
        FROM appview_pds_read_state_authority authority
        WHERE authority.manifest_cid IS NOT NULL
          AND ((authority.projection_ready AND authority.last_accessed_at < \(before))
            OR (NOT authority.projection_ready AND (
              EXISTS (SELECT 1 FROM appview_pds_read_state_exact e WHERE e.viewer_did = authority.viewer_did)
              OR EXISTS (SELECT 1 FROM appview_pds_read_state_boundaries b WHERE b.viewer_did = authority.viewer_did))))
          AND NOT EXISTS (SELECT 1 FROM appview_ingestion_inbox i
            WHERE i.repo_did = authority.viewer_did AND i.status IN ('pending', 'retry', 'leased', 'dead_letter'))
          AND NOT EXISTS (SELECT 1 FROM appview_ingestion_reconciliation_requests r
            WHERE r.repo_did = authority.viewer_did AND r.status IN ('pending', 'leased', 'failed'))
          AND NOT EXISTS (SELECT 1 FROM appview_ingestion_leases lease
            WHERE lease.lease_name = 'pds-read-state-rebuild:' || encode(sha256(convert_to(authority.viewer_did, 'UTF8')), 'hex')
              AND lease.released_at IS NULL AND lease.lease_expires_at > \(at))
        ORDER BY authority.projection_ready, authority.last_accessed_at, authority.viewer_did
        LIMIT 1 FOR UPDATE OF authority SKIP LOCKED
        """, logger: logger)
      var candidate: (String, Bool)?
      for try await row in candidates { candidate = try row.decode((String, Bool).self) }
      guard let (viewer, wasReady) = candidate else {
        return PDSReadStateEvictionBatch(viewerDid: nil, deletedRows: 0, hasMore: false)
      }
      try await connection.query(
        "UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer) AND projection_ready", logger: logger)
      var deleted = 0
      for table in ["appview_pds_read_state_exact", "appview_pds_read_state_boundaries"] {
        for try await row in try await connection.query(
          """
          WITH removed AS (
            DELETE FROM \(unescaped: table) WHERE ctid IN (
              SELECT ctid FROM \(unescaped: table) WHERE viewer_did = \(viewer) LIMIT \(limit)
            ) RETURNING 1
          ) SELECT COUNT(*)::int FROM removed
          """, logger: logger) { deleted += try row.decode(Int.self) }
      }
      return PDSReadStateEvictionBatch(viewerDid: wasReady ? viewer : nil, deletedRows: deleted, hasMore: true)
    }
  }
}
