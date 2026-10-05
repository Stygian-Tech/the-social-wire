import FinanceCore
import Foundation
import GatewayCore
import Logging
import PostgresNIO

actor FinanceSelectionProjection {
  let pool: PostgresClient
  let repo: ATProtoAuthenticatedRepoClient
  let logger: Logger

  init(pool: PostgresClient, repo: ATProtoAuthenticatedRepoClient, logger: Logger) {
    self.pool = pool; self.repo = repo; self.logger = logger
  }

  func selections(viewerDID: String?, refresh: Bool, now: Date) async throws -> (instruments: [String], sectors: [String]) {
    guard let viewerDID else { return ([], []) }
    var lastSync: Date?
    let syncRows = try await pool.query("SELECT synced_at FROM finance_selection_sync WHERE viewer_did = \(viewerDID)", logger: logger)
    for try await row in syncRows { lastSync = try row.decode(Date.self) }
    if refresh || lastSync.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
      do {
      // Selections are explicitly public. Never forward gateway-bound credentials to the PDS.
      let refreshStartedAt = now
      var cursor: String?; var observedCursors = Set<String>(); var values: [(String, String, String)] = []
      for _ in 0..<20 {
        let page = try await repo.listRecords(auth: nil, repo: viewerDID,
          collection: "app.thesocialwire.finance.selection", limit: 100, cursor: cursor, reverse: false, requireResolvedRepository: true)
        for record in page.records {
          guard record.value.values["$type"] as? String == "app.thesocialwire.finance.selection",
            let kind = record.value.values["kind"] as? String, ["instrument", "sector"].contains(kind),
            let reference = record.value.values["reference"] as? String, !reference.isEmpty, reference.utf8.count <= 128,
            let key = record.uri.split(separator: "/").last.map(String.init),
            record.uri == "at://\(viewerDID)/app.thesocialwire.finance.selection/\(key)",
            key == FinanceIdentity.selectionRecordKey(kind: kind, id: reference)
          else { continue }
          values.append((key, kind, reference))
        }
        cursor = page.cursor
        guard let next = cursor else { break }
        guard observedCursors.insert(next).inserted else { throw WireServingError.unavailable }
      }
      guard cursor == nil else { throw WireServingError.unavailable }
      let selected = values
      try await pool.withTransaction(logger: logger) { connection in
        // Serialize refreshes with ingestion so replacement is never partially visible.
        try await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(\(viewerDID), 91827))", logger: self.logger)
        try await connection.query("""
          INSERT INTO finance_selection_versions (viewer_did,record_key,event_at,repo_rev,is_deleted)
          SELECT viewer_did,record_key,updated_at,'',FALSE FROM finance_selections WHERE viewer_did=\(viewerDID)
          ON CONFLICT (viewer_did,record_key) DO NOTHING
          """, logger: self.logger)
        try await connection.query("""
          DELETE FROM finance_selections selection WHERE viewer_did = \(viewerDID)
            AND NOT EXISTS (SELECT 1 FROM finance_selection_versions version
              WHERE version.viewer_did=selection.viewer_did AND version.record_key=selection.record_key
                AND version.event_at > \(refreshStartedAt))
          """, logger: self.logger)
        // Completed snapshots advance all absent known records to deletion tombstones.
        let selectedKeys = selected.map { $0.0 }
        try await connection.query("""
          UPDATE finance_selection_versions SET event_at=\(refreshStartedAt), repo_rev='', is_deleted=TRUE
          WHERE viewer_did=\(viewerDID) AND event_at <= \(refreshStartedAt)
            AND NOT (record_key = ANY(\(selectedKeys)::text[]))
          """, logger: self.logger)
        for (key, kind, reference) in selected {
          let accepted = try await connection.query("""
            INSERT INTO finance_selection_versions (viewer_did, record_key, event_at, repo_rev, is_deleted)
            VALUES (\(viewerDID), \(key), \(refreshStartedAt), '', FALSE)
            ON CONFLICT (viewer_did, record_key) DO UPDATE SET
              event_at=EXCLUDED.event_at, repo_rev='', is_deleted=FALSE
            WHERE finance_selection_versions.event_at <= EXCLUDED.event_at
            RETURNING record_key
            """, logger: self.logger)
          var apply = false
          for try await _ in accepted { apply = true }
          guard apply else { continue }
          try await connection.query("""
            INSERT INTO finance_selections (viewer_did, record_key, kind, reference, updated_at)
            VALUES (\(viewerDID), \(key), \(kind), \(reference), \(refreshStartedAt))
            ON CONFLICT (viewer_did, record_key) DO UPDATE SET kind=EXCLUDED.kind, reference=EXCLUDED.reference, updated_at=EXCLUDED.updated_at
            """, logger: self.logger)
        }
        try await connection.query("""
          INSERT INTO finance_selection_sync (viewer_did, synced_at) VALUES (\(viewerDID), \(now))
          ON CONFLICT (viewer_did) DO UPDATE SET synced_at=EXCLUDED.synced_at
          """, logger: self.logger)
      }
      } catch {
        if error is CancellationError { throw error }
        if refresh { throw WireServingError.unavailable }
        logger.warning("Finance PDS reconciliation failed; retaining last projected selections")
      }
    }
    var instruments: [String] = []; var sectors: [String] = []
    let rows = try await pool.query("SELECT kind, reference FROM finance_selections WHERE viewer_did = \(viewerDID) ORDER BY record_key", logger: logger)
    for try await row in rows {
      let (kind, reference) = try row.decode((String, String).self)
      if kind == "instrument" { instruments.append(reference) } else { sectors.append(reference) }
    }
    return (instruments, sectors)
  }
}
