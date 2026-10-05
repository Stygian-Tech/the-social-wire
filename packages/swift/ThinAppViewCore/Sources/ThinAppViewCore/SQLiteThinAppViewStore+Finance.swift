@preconcurrency import GRDB

extension SQLiteThinAppViewStore: FinanceSelectionStoring {
  static func migrateFinance(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS finance_selection_sync (viewer_did TEXT PRIMARY KEY, synced_at DOUBLE NOT NULL);
      CREATE TABLE IF NOT EXISTS finance_selections (
        viewer_did TEXT NOT NULL, record_key TEXT NOT NULL, kind TEXT NOT NULL,
        reference TEXT NOT NULL, updated_at DOUBLE NOT NULL, PRIMARY KEY(viewer_did, record_key));
      CREATE TABLE IF NOT EXISTS finance_selection_versions (
        viewer_did TEXT NOT NULL, record_key TEXT NOT NULL, event_at DOUBLE NOT NULL,
        repo_rev TEXT NOT NULL, is_deleted BOOLEAN NOT NULL, PRIMARY KEY(viewer_did, record_key));
      """)
  }
  public func applyFinanceSelection(_ mutation: FinanceSelectionMutation) async throws {
    try await db.write { database in
      let existing = try Row.fetchOne(database, sql: "SELECT event_at, repo_rev FROM finance_selection_versions WHERE viewer_did=? AND record_key=?",
        arguments: [mutation.viewerDID, mutation.recordKey])
      if let existing {
        let time: Double = existing["event_at"]
        let revision: String = existing["repo_rev"]
        guard time < mutation.eventAt.timeIntervalSince1970 ||
          (time == mutation.eventAt.timeIntervalSince1970 && revision < mutation.repoRev) else { return }
      }
      try database.execute(sql: """
        INSERT INTO finance_selection_versions VALUES (?,?,?,?,?)
        ON CONFLICT (viewer_did, record_key) DO UPDATE SET event_at=excluded.event_at,
          repo_rev=excluded.repo_rev, is_deleted=excluded.is_deleted
        """, arguments: [mutation.viewerDID, mutation.recordKey, mutation.eventAt.timeIntervalSince1970, mutation.repoRev, mutation.isDeleted])
      if let kind = mutation.kind, let reference = mutation.reference {
        try database.execute(sql: """
          INSERT INTO finance_selections VALUES (?,?,?,?,?)
          ON CONFLICT(viewer_did, record_key) DO UPDATE SET kind=excluded.kind,
            reference=excluded.reference, updated_at=excluded.updated_at
          """, arguments: [mutation.viewerDID, mutation.recordKey, kind, reference, mutation.eventAt.timeIntervalSince1970])
      } else {
        try database.execute(sql: "DELETE FROM finance_selections WHERE viewer_did=? AND record_key=?", arguments: [mutation.viewerDID, mutation.recordKey])
      }
    }
  }
}
