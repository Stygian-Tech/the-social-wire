import SportsCore
import Foundation
import GatewayCore
import Logging
import PostgresNIO

actor SportsSelectionProjection {
  let pool: PostgresClient
  let repo: ATProtoAuthenticatedRepoClient
  let logger: Logger

  init(pool: PostgresClient, repo: ATProtoAuthenticatedRepoClient, logger: Logger) {
    self.pool = pool; self.repo = repo; self.logger = logger
  }

  func selections(viewerDID: String?, refresh: Bool, now: Date) async throws -> [SportsSelection] {
    guard let viewerDID else { return [] }
    var lastSync: Date?
    let syncRows = try await pool.query("SELECT synced_at FROM sports_selection_sync WHERE viewer_did = \(viewerDID)", logger: logger)
    for try await row in syncRows { lastSync = try row.decode(Date.self) }
    if refresh || lastSync.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
      do {
      // Selections are explicitly public. Never forward gateway-bound credentials to the PDS.
      let refreshStartedAt = now
      var cursor: String?; var observedCursors = Set<String>(); var values: [(String, String, String)] = []
      for _ in 0..<20 {
        let page = try await repo.listRecords(auth: nil, repo: viewerDID,
          collection: "app.thesocialwire.sports.selection", limit: 100, cursor: cursor, reverse: false, requireResolvedRepository: true)
        for record in page.records {
          guard record.value.values["$type"] as? String == "app.thesocialwire.sports.selection",
            let action = record.value.values["action"] as? String, ["follow", "mute"].contains(action),
            let reference = record.value.values["reference"] as? String, !reference.isEmpty, reference.utf8.count <= 128,
            let key = record.uri.split(separator: "/").last.map(String.init),
            record.uri == "at://\(viewerDID)/app.thesocialwire.sports.selection/\(key)",
            key == SportsIdentity.selectionRecordKey(id: reference)
          else { continue }
          values.append((key, action, reference))
        }
        cursor = page.cursor
        guard let next = cursor else { break }
        guard observedCursors.insert(next).inserted else { throw WireServingError.unavailable }
      }
      guard cursor == nil else { throw WireServingError.unavailable }
      let selected = values
      try await pool.withTransaction(logger: logger) { connection in
        // Serialize refreshes with ingestion so replacement is never partially visible.
        try await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(\(viewerDID), 91828))", logger: self.logger)
        try await connection.query("""
          INSERT INTO sports_selection_versions (viewer_did,record_key,event_at,repo_rev,is_deleted)
          SELECT viewer_did,record_key,updated_at,'',FALSE FROM sports_selections WHERE viewer_did=\(viewerDID)
          ON CONFLICT (viewer_did,record_key) DO NOTHING
          """, logger: self.logger)
        try await connection.query("""
          DELETE FROM sports_selections selection WHERE viewer_did = \(viewerDID)
            AND NOT EXISTS (SELECT 1 FROM sports_selection_versions version
              WHERE version.viewer_did=selection.viewer_did AND version.record_key=selection.record_key
                AND version.event_at > \(refreshStartedAt))
          """, logger: self.logger)
        // Completed snapshots advance all absent known records to deletion tombstones.
        let selectedKeys = selected.map { $0.0 }
        try await connection.query("""
          UPDATE sports_selection_versions SET event_at=\(refreshStartedAt), repo_rev='', is_deleted=TRUE
          WHERE viewer_did=\(viewerDID) AND event_at <= \(refreshStartedAt)
            AND NOT (record_key = ANY(\(selectedKeys)::text[]))
          """, logger: self.logger)
        for (key, action, reference) in selected {
          let accepted = try await connection.query("""
            INSERT INTO sports_selection_versions (viewer_did, record_key, event_at, repo_rev, is_deleted)
            VALUES (\(viewerDID), \(key), \(refreshStartedAt), '', FALSE)
            ON CONFLICT (viewer_did, record_key) DO UPDATE SET
              event_at=EXCLUDED.event_at, repo_rev='', is_deleted=FALSE
            WHERE sports_selection_versions.event_at <= EXCLUDED.event_at
            RETURNING record_key
            """, logger: self.logger)
          var apply = false
          for try await _ in accepted { apply = true }
          guard apply else { continue }
          try await connection.query("""
            INSERT INTO sports_selections (viewer_did, record_key, action, reference, updated_at)
            VALUES (\(viewerDID), \(key), \(action), \(reference), \(refreshStartedAt))
            ON CONFLICT (viewer_did, record_key) DO UPDATE SET action=EXCLUDED.action, reference=EXCLUDED.reference, updated_at=EXCLUDED.updated_at
            """, logger: self.logger)
        }
        try await connection.query("""
          INSERT INTO sports_selection_sync (viewer_did, synced_at) VALUES (\(viewerDID), \(now))
          ON CONFLICT (viewer_did) DO UPDATE SET synced_at=EXCLUDED.synced_at
          """, logger: self.logger)
      }
      } catch {
        if error is CancellationError { throw error }
        if refresh { throw WireServingError.unavailable }
        logger.warning("Sports PDS reconciliation failed; retaining last projected selections")
      }
    }
    var result: [SportsSelection] = []
    let rows = try await pool.query("SELECT action, reference FROM sports_selections WHERE viewer_did = \(viewerDID) ORDER BY record_key", logger: logger)
    for try await row in rows {
      let (action, reference) = try row.decode((String, String).self)
      result.append(SportsSelection(reference: reference, action: action))
    }
    return result
  }
}
