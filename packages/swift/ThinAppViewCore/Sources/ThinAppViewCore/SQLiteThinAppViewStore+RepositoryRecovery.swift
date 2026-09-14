@preconcurrency import GRDB
import Foundation

extension SQLiteThinAppViewStore: PDSRepositoryRecoveryStore {
  static func migrateRepositoryRecovery(_ db: Database) throws {
    for table in ["appview_ingestion_inbox", "appview_ingestion_reconciliation_requests"] {
      if try !db.columns(in: table).contains(where: { $0.name == "recovery_state" }) {
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN recovery_state TEXT")
      }
    }
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_repository_recovery_records (
        environment TEXT NOT NULL, source_generation TEXT NOT NULL, recovery_key TEXT NOT NULL,
        sync_sequence INTEGER, request_id TEXT, uri TEXT NOT NULL,
        PRIMARY KEY (environment, source_generation, recovery_key, uri),
        CHECK ((sync_sequence IS NULL) <> (request_id IS NULL)),
        FOREIGN KEY (environment, source_generation, sync_sequence)
          REFERENCES appview_ingestion_inbox (environment, source_generation, seq) ON DELETE CASCADE,
        FOREIGN KEY (environment, request_id)
          REFERENCES appview_ingestion_reconciliation_requests (environment, id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS appview_repository_recovery_request_idx
        ON appview_repository_recovery_records (environment, request_id, source_generation, recovery_key, uri) WHERE request_id IS NOT NULL;
      CREATE INDEX IF NOT EXISTS appview_repository_recovery_sync_idx
        ON appview_repository_recovery_records (environment, source_generation, sync_sequence, recovery_key, uri)
        WHERE sync_sequence IS NOT NULL;
      """)
  }

  func loadRepositoryRecovery(_ context: PDSRepositoryRecoveryContext) async throws
    -> PDSRepositoryRecoveryState {
    try await db.write { db in
      let json = try Self.lockedRepositoryRecovery(context, db: db)
      if let json {
        return try JSONDecoder().decode(PDSRepositoryRecoveryState.self, from: Data(json.utf8))
      }
      let state = PDSRepositoryRecoveryState()
      let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
      if let requestId = context.requestId {
        try db.execute(sql: """
          UPDATE appview_ingestion_reconciliation_requests SET recovery_state = ?
          WHERE environment = ? AND id = ?
          """, arguments: [encoded, context.environment, requestId])
      } else {
        try db.execute(sql: """
          UPDATE appview_ingestion_inbox SET recovery_state = ?
          WHERE environment = ? AND source_generation = ? AND seq = ?
          """, arguments: [encoded, context.environment, context.sourceGeneration, context.sequence])
      }
      return state
    }
  }

  @discardableResult
  func saveRepositoryRecovery(_ context: PDSRepositoryRecoveryContext,
                              state: PDSRepositoryRecoveryState,
                              observedURIs: [String], finish: Bool) async throws -> PDSRepositoryRecoveryState {
    try await db.write { db in
      var next = state
      let key = context.key + ":" + state.snapshotId
      let previous = try Self.lockedRepositoryRecovery(context, db: db)
      if let previous,
         try JSONDecoder().decode(PDSRepositoryRecoveryState.self, from: Data(previous.utf8)).completed {
        if finish { return try JSONDecoder().decode(PDSRepositoryRecoveryState.self, from: Data(previous.utf8)) }
        throw AppViewIngestionInboxStoreError.staleLease
      }
      for uri in observedURIs {
        try db.execute(sql: """
          INSERT OR IGNORE INTO appview_repository_recovery_records
            (environment, source_generation, recovery_key, sync_sequence, request_id, uri)
          VALUES (?, ?, ?, ?, ?, ?)
          """, arguments: [context.environment, context.sourceGeneration, key,
            context.requestId == nil ? context.sequence : nil, context.requestId, uri])
      }
      if finish {
        guard ThinAppViewConfig.canonicalContentCollections.allSatisfy({ state.collections[$0]?.complete == true }) else {
          throw AppViewIngestionInboxStoreError.invalidRow
        }
        if !state.pruningComplete {
          let rows: [Row]
          if let createdAt = state.pruneCreatedAt, let uri = state.pruneURI {
            rows = try Row.fetchAll(db, sql: """
              SELECT created_at, uri FROM content_items WHERE author_did = ?
                AND (created_at, uri) < (?, ?) ORDER BY created_at DESC, uri DESC LIMIT 1000
            """, arguments: [context.repoDid, Self.recoveryDate(createdAt), uri])
          } else {
            rows = try Row.fetchAll(db, sql: """
              SELECT created_at, uri FROM content_items WHERE author_did = ?
              ORDER BY created_at DESC, uri DESC LIMIT 1000
            """, arguments: [context.repoDid])
          }
          for row in rows {
            let uri: String = row["uri"]
            let rawCreatedAt: String = row["created_at"]
            guard let createdAt = ISO8601DateFormatter().date(from: rawCreatedAt) else {
              throw AppViewIngestionInboxStoreError.invalidRow
            }
            next.pruneCreatedAt = createdAt
            next.pruneURI = uri
            try db.execute(sql: """
              DELETE FROM content_items WHERE uri = ? AND author_did = ? AND indexed_at <= ?
                AND NOT EXISTS (SELECT 1 FROM appview_repository_recovery_records observed
                  WHERE observed.environment = ? AND observed.source_generation = ?
                    AND observed.recovery_key = ? AND observed.uri = content_items.uri)
            """, arguments: [uri, context.repoDid, Self.recoveryDate(state.startedAt),
                context.environment, context.sourceGeneration, key])
          }
          next.pruningComplete = rows.count < 1000
        }
        next.completed = false
        if next.pruningComplete {
          if let requestId = context.requestId {
            try db.execute(sql: """
            DELETE FROM appview_repository_recovery_records
            WHERE environment = ? AND source_generation = ? AND (recovery_key, uri) IN (
              SELECT recovery_key, uri FROM appview_repository_recovery_records
              WHERE environment = ? AND source_generation = ?
                AND request_id = ? ORDER BY recovery_key, uri LIMIT 1000
            )
            """, arguments: [context.environment, context.sourceGeneration,
                context.environment, context.sourceGeneration, requestId])
          } else {
            try db.execute(sql: """
            DELETE FROM appview_repository_recovery_records
            WHERE environment = ? AND source_generation = ? AND (recovery_key, uri) IN (
              SELECT recovery_key, uri FROM appview_repository_recovery_records
              WHERE environment = ? AND source_generation = ?
                AND sync_sequence = ? ORDER BY recovery_key, uri LIMIT 1000
            )
            """, arguments: [context.environment, context.sourceGeneration,
                context.environment, context.sourceGeneration, context.sequence])
          }
          next.completed = db.changesCount < 1000
        }
      }
      let json = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
      if let requestId = context.requestId {
        try db.execute(sql: """
          UPDATE appview_ingestion_reconciliation_requests SET recovery_state = ?
          WHERE environment = ? AND id = ?
          """, arguments: [json, context.environment, requestId])
      } else {
        try db.execute(sql: """
          UPDATE appview_ingestion_inbox SET recovery_state = ?
          WHERE environment = ? AND source_generation = ? AND seq = ?
          """, arguments: [json, context.environment, context.sourceGeneration, context.sequence])
      }
      return next
    }
  }

  func yieldRepositoryRecovery(_ context: PDSRepositoryRecoveryContext) async throws {
    try await db.write { db in
      _ = try Self.lockedRepositoryRecovery(context, db: db)
      let now = Date()
      if let requestId = context.requestId {
        try db.execute(sql: """
          UPDATE appview_ingestion_reconciliation_requests SET status = 'pending',
            next_attempt_at = ?, lease_owner = NULL, lease_token = NULL,
            lease_expires_at = NULL, updated_at = ? WHERE environment = ? AND id = ?
          """, arguments: [Self.recoveryDate(now.addingTimeInterval(0.25)), Self.recoveryDate(now),
            context.environment, requestId])
      } else {
        try db.execute(sql: """
          UPDATE appview_ingestion_inbox SET status = 'retry', next_attempt_at = ?,
            lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
            failure_category = NULL, failure_reason = NULL, updated_at = ?
          WHERE environment = ? AND source_generation = ? AND seq = ?
          """, arguments: [Self.recoveryDate(now.addingTimeInterval(0.25)), Self.recoveryDate(now),
            context.environment, context.sourceGeneration, context.sequence])
      }
    }
  }

  private static func lockedRepositoryRecovery(_ context: PDSRepositoryRecoveryContext,
                                               db: Database) throws -> String? {
    let row: Row?
    if let requestId = context.requestId {
      row = try Row.fetchOne(db, sql: """
        SELECT recovery_state FROM appview_ingestion_reconciliation_requests
        WHERE environment = ? AND source_generation = ? AND id = ? AND repo_did = ?
          AND trigger_seq = ? AND status = 'leased' AND lease_owner = ? AND lease_token = ?
          AND lease_expires_at > ?
        """, arguments: [context.environment, context.sourceGeneration, requestId, context.repoDid,
          context.sequence, context.workerId, context.leaseToken, recoveryDate(Date())])
    } else {
      row = try Row.fetchOne(db, sql: """
        SELECT recovery_state FROM appview_ingestion_inbox
        WHERE environment = ? AND source_generation = ? AND seq = ? AND repo_did = ?
          AND status = 'leased' AND lease_owner = ? AND lease_token = ? AND lease_expires_at > ?
        """, arguments: [context.environment, context.sourceGeneration, context.sequence,
          context.repoDid, context.workerId, context.leaseToken, recoveryDate(Date())])
    }
    guard let row else { throw AppViewIngestionInboxStoreError.staleLease }
    return row["recovery_state"]
  }

  private static func recoveryDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
  }
}
