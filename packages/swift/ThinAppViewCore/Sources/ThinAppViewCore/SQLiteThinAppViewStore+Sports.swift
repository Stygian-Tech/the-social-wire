@preconcurrency import GRDB

extension SQLiteThinAppViewStore: SportsSelectionStoring {
  static func migrateSports(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS sports_selection_sync (viewer_did TEXT PRIMARY KEY, synced_at DOUBLE NOT NULL);
      CREATE TABLE IF NOT EXISTS sports_selections (
        viewer_did TEXT NOT NULL, record_key TEXT NOT NULL, action TEXT NOT NULL,
        reference TEXT NOT NULL, updated_at DOUBLE NOT NULL, PRIMARY KEY(viewer_did, record_key));
      CREATE TABLE IF NOT EXISTS sports_selection_versions (
        viewer_did TEXT NOT NULL, record_key TEXT NOT NULL, event_at DOUBLE NOT NULL,
        repo_rev TEXT NOT NULL, is_deleted BOOLEAN NOT NULL, PRIMARY KEY(viewer_did, record_key));
      """)
  }
  public func applySportsSelection(_ mutation: SportsSelectionMutation) async throws {
    try await db.write { database in
      let existing = try Row.fetchOne(database, sql: "SELECT event_at, repo_rev FROM sports_selection_versions WHERE viewer_did=? AND record_key=?",
        arguments: [mutation.viewerDID, mutation.recordKey])
      if let existing {
        let time: Double = existing["event_at"]
        let revision: String = existing["repo_rev"]
        guard time < mutation.eventAt.timeIntervalSince1970 ||
          (time == mutation.eventAt.timeIntervalSince1970 && revision < mutation.repoRev) else { return }
      }
      try database.execute(sql: """
        INSERT INTO sports_selection_versions VALUES (?,?,?,?,?)
        ON CONFLICT (viewer_did, record_key) DO UPDATE SET event_at=excluded.event_at,
          repo_rev=excluded.repo_rev, is_deleted=excluded.is_deleted
        """, arguments: [mutation.viewerDID, mutation.recordKey, mutation.eventAt.timeIntervalSince1970, mutation.repoRev, mutation.isDeleted])
      if let action = mutation.action, let reference = mutation.reference {
        try database.execute(sql: """
          INSERT INTO sports_selections VALUES (?,?,?,?,?)
          ON CONFLICT(viewer_did, record_key) DO UPDATE SET action=excluded.action,
            reference=excluded.reference, updated_at=excluded.updated_at
          """, arguments: [mutation.viewerDID, mutation.recordKey, action, reference, mutation.eventAt.timeIntervalSince1970])
      } else {
        try database.execute(sql: "DELETE FROM sports_selections WHERE viewer_did=? AND record_key=?", arguments: [mutation.viewerDID, mutation.recordKey])
      }
    }
  }
}
