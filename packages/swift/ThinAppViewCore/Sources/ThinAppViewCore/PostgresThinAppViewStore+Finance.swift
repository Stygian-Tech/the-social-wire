import PostgresNIO

extension PostgresThinAppViewStore: FinanceSelectionStoring {
  public func applyFinanceSelection(_ mutation: FinanceSelectionMutation) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(\(mutation.viewerDID), 91827))", logger: self.logger)
      let accepted = try await connection.query("""
        INSERT INTO finance_selection_versions (viewer_did, record_key, event_at, repo_rev, is_deleted)
        SELECT \(mutation.viewerDID), \(mutation.recordKey), \(mutation.eventAt), \(mutation.repoRev), \(mutation.isDeleted)
        WHERE NOT EXISTS (SELECT 1 FROM finance_selection_sync
          WHERE viewer_did=\(mutation.viewerDID) AND synced_at > \(mutation.eventAt))
        ON CONFLICT (viewer_did, record_key) DO UPDATE SET
          event_at=EXCLUDED.event_at, repo_rev=EXCLUDED.repo_rev, is_deleted=EXCLUDED.is_deleted
        WHERE finance_selection_versions.event_at < EXCLUDED.event_at OR
          (finance_selection_versions.event_at = EXCLUDED.event_at AND finance_selection_versions.repo_rev < EXCLUDED.repo_rev)
        RETURNING record_key
        """, logger: self.logger)
      var applied = false
      for try await _ in accepted { applied = true }
      guard applied else { return }
      if mutation.isDeleted {
        try await connection.query("DELETE FROM finance_selections WHERE viewer_did=\(mutation.viewerDID) AND record_key=\(mutation.recordKey)", logger: self.logger)
      } else if let kind = mutation.kind, let reference = mutation.reference {
        try await connection.query("""
          INSERT INTO finance_selections (viewer_did, record_key, kind, reference, updated_at)
          VALUES (\(mutation.viewerDID), \(mutation.recordKey), \(kind), \(reference), \(mutation.eventAt))
          ON CONFLICT (viewer_did, record_key) DO UPDATE SET
            kind=EXCLUDED.kind, reference=EXCLUDED.reference, updated_at=EXCLUDED.updated_at
          """, logger: self.logger)
      }
    }
  }
}
