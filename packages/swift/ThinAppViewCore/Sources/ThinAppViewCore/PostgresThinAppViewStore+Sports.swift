import PostgresNIO

extension PostgresThinAppViewStore: SportsSelectionStoring {
  public func applySportsSelection(_ mutation: SportsSelectionMutation) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(\(mutation.viewerDID), 91828))", logger: self.logger)
      let accepted = try await connection.query("""
        INSERT INTO sports_selection_versions (viewer_did, record_key, event_at, repo_rev, is_deleted)
        SELECT \(mutation.viewerDID), \(mutation.recordKey), \(mutation.eventAt), \(mutation.repoRev), \(mutation.isDeleted)
        WHERE NOT EXISTS (SELECT 1 FROM sports_selection_sync
          WHERE viewer_did=\(mutation.viewerDID) AND synced_at > \(mutation.eventAt))
        ON CONFLICT (viewer_did, record_key) DO UPDATE SET
          event_at=EXCLUDED.event_at, repo_rev=EXCLUDED.repo_rev, is_deleted=EXCLUDED.is_deleted
        WHERE sports_selection_versions.event_at < EXCLUDED.event_at OR
          (sports_selection_versions.event_at = EXCLUDED.event_at AND sports_selection_versions.repo_rev < EXCLUDED.repo_rev)
        RETURNING record_key
        """, logger: self.logger)
      var applied = false
      for try await _ in accepted { applied = true }
      guard applied else { return }
      if mutation.isDeleted {
        try await connection.query("DELETE FROM sports_selections WHERE viewer_did=\(mutation.viewerDID) AND record_key=\(mutation.recordKey)", logger: self.logger)
      } else if let action = mutation.action, let reference = mutation.reference {
        try await connection.query("""
          INSERT INTO sports_selections (viewer_did, record_key, action, reference, updated_at)
          VALUES (\(mutation.viewerDID), \(mutation.recordKey), \(action), \(reference), \(mutation.eventAt))
          ON CONFLICT (viewer_did, record_key) DO UPDATE SET
            action=EXCLUDED.action, reference=EXCLUDED.reference, updated_at=EXCLUDED.updated_at
          """, logger: self.logger)
      }
    }
  }
}
