import Foundation
import PostgresNIO

extension PostgresThinAppViewStore: PDSRepositoryRecoveryStore {
  func loadRepositoryRecovery(_ context: PDSRepositoryRecoveryContext) async throws
    -> PDSRepositoryRecoveryState {
    try await repositoryRecoveryTransaction { connection in
      let json = try await self.lockedRepositoryRecovery(context, on: connection)
      if let json {
        return try JSONDecoder().decode(PDSRepositoryRecoveryState.self, from: Data(json.utf8))
      }
      let state = PDSRepositoryRecoveryState()
      try await self.writeRepositoryRecovery(context, state: state, on: connection)
      return state
    }
  }

  @discardableResult
  func saveRepositoryRecovery(_ context: PDSRepositoryRecoveryContext,
                              state: PDSRepositoryRecoveryState,
                              observedURIs: [String], finish: Bool) async throws -> PDSRepositoryRecoveryState {
    try await repositoryRecoveryTransaction { connection in
      var next = state
      let key = context.key + ":" + state.snapshotId
      let syncSequence: Int64? = context.requestId == nil ? context.sequence : nil
      let previous = try await self.lockedRepositoryRecovery(context, on: connection)
      if let previous,
         try JSONDecoder().decode(PDSRepositoryRecoveryState.self, from: Data(previous.utf8)).completed {
        if finish { return try JSONDecoder().decode(PDSRepositoryRecoveryState.self, from: Data(previous.utf8)) }
        throw AppViewIngestionInboxStoreError.staleLease
      }
      if !observedURIs.isEmpty {
        try await connection.query("""
          INSERT INTO appview_repository_recovery_records
            (environment, source_generation, recovery_key, sync_sequence, request_id, uri)
          SELECT \(context.environment), \(context.sourceGeneration), \(key),
                 \(syncSequence), \(context.requestId), uri FROM unnest(\(observedURIs)::text[]) AS uri
          ON CONFLICT DO NOTHING
          """, logger: self.logger)
      }
      if finish {
        guard ThinAppViewConfig.canonicalContentCollections.allSatisfy({ state.collections[$0]?.complete == true }) else {
          throw AppViewIngestionInboxStoreError.invalidRow
        }
        if !state.pruningComplete {
          let query: PostgresQuery
          if let createdAt = state.pruneCreatedAt, let uri = state.pruneURI {
            query = """
              SELECT created_at, uri FROM content_items WHERE author_did = \(context.repoDid)
                AND (created_at, uri) < (\(createdAt), \(uri))
              ORDER BY created_at DESC, uri DESC LIMIT 1000
            """
          } else {
            query = """
              SELECT created_at, uri FROM content_items WHERE author_did = \(context.repoDid)
              ORDER BY created_at DESC, uri DESC LIMIT 1000
            """
          }
          var candidates: [String] = []
          for try await row in try await connection.query(query, logger: self.logger) {
            let (createdAt, uri) = try row.decode((Date, String).self)
            candidates.append(uri)
            next.pruneCreatedAt = createdAt
            next.pruneURI = uri
          }
          // Limit candidate traversal before checking presence. Retained prefixes are visited once,
          // using the existing (author_did, created_at DESC, uri DESC) index.
          if !candidates.isEmpty {
            try await connection.query("""
              DELETE FROM content_items WHERE author_did = \(context.repoDid)
                AND indexed_at <= \(state.startedAt) AND uri = ANY(\(candidates))
                AND NOT EXISTS (SELECT 1 FROM appview_repository_recovery_records observed
                  WHERE observed.environment = \(context.environment)
                    AND observed.source_generation = \(context.sourceGeneration)
                    AND observed.recovery_key = \(key) AND observed.uri = content_items.uri)
            """, logger: self.logger)
          }
          next.pruningComplete = candidates.count < 1000
        }
        next.completed = false
        if next.pruningComplete {
          var count = 0
          let cleanup: PostgresQuery
          if let requestId = context.requestId {
            cleanup = """
            DELETE FROM appview_repository_recovery_records WHERE
              environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
              AND (recovery_key, uri) IN (
                SELECT recovery_key, uri FROM appview_repository_recovery_records
                WHERE environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
                  AND request_id = \(requestId)
                ORDER BY recovery_key, uri LIMIT 1000
              ) RETURNING uri
            """
          } else {
            cleanup = """
            DELETE FROM appview_repository_recovery_records WHERE
              environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
              AND (recovery_key, uri) IN (
                SELECT recovery_key, uri FROM appview_repository_recovery_records
                WHERE environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
                  AND sync_sequence = \(context.sequence)
                ORDER BY recovery_key, uri LIMIT 1000
              ) RETURNING uri
            """
          }
          let rows = try await connection.query(cleanup, logger: self.logger)
          for try await _ in rows { count += 1 }
          next.completed = count < 1000
        }
      }
      let json = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
      if let requestId = context.requestId {
        try await connection.query("""
          UPDATE appview_ingestion_reconciliation_requests SET recovery_state = \(json)
          WHERE environment = \(context.environment) AND id = \(requestId)
          """, logger: self.logger)
      } else {
        try await connection.query("""
          UPDATE appview_ingestion_inbox SET recovery_state = \(json)
          WHERE environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
            AND seq = \(context.sequence)
          """, logger: self.logger)
      }
      return next
    }
  }

  func yieldRepositoryRecovery(_ context: PDSRepositoryRecoveryContext) async throws {
    try await repositoryRecoveryTransaction { connection in
      _ = try await self.lockedRepositoryRecovery(context, on: connection)
      let now = Date()
      let next = now.addingTimeInterval(0.25)
      if let requestId = context.requestId {
        try await connection.query("""
          UPDATE appview_ingestion_reconciliation_requests SET status = 'pending',
            next_attempt_at = \(next), lease_owner = NULL, lease_token = NULL,
            lease_expires_at = NULL, updated_at = \(now)
          WHERE environment = \(context.environment) AND id = \(requestId)
          """, logger: self.logger)
      } else {
        try await connection.query("""
          UPDATE appview_ingestion_inbox SET status = 'retry', next_attempt_at = \(next),
            lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
            failure_category = NULL, failure_reason = NULL, updated_at = \(now)
          WHERE environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
            AND seq = \(context.sequence)
          """, logger: self.logger)
      }
    }
  }

  private func repositoryRecoveryTransaction<Result>(
    _ body: (PostgresConnection) async throws -> sending Result
  ) async throws -> sending Result {
    do { return try await pool.withTransaction(logger: logger, body) }
    catch let error as PostgresTransactionError {
      if let storage = error.closureError as? AppViewIngestionInboxStoreError { throw storage }
      throw error
    }
  }

  private func writeRepositoryRecovery(_ context: PDSRepositoryRecoveryContext,
                                      state: PDSRepositoryRecoveryState,
                                      on connection: PostgresConnection) async throws {
    let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    if let requestId = context.requestId {
      try await connection.query("""
        UPDATE appview_ingestion_reconciliation_requests SET recovery_state = \(json)
        WHERE environment = \(context.environment) AND id = \(requestId)
        """, logger: logger)
    } else {
      try await connection.query("""
        UPDATE appview_ingestion_inbox SET recovery_state = \(json)
        WHERE environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
          AND seq = \(context.sequence)
        """, logger: logger)
    }
  }

  private func lockedRepositoryRecovery(_ context: PDSRepositoryRecoveryContext,
                                        on connection: PostgresConnection) async throws -> String? {
    let now = Date()
    let query: PostgresQuery
    if let requestId = context.requestId {
      query = """
        SELECT recovery_state FROM appview_ingestion_reconciliation_requests
        WHERE environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
          AND id = \(requestId) AND repo_did = \(context.repoDid)
          AND trigger_seq = \(context.sequence) AND status = 'leased'
          AND lease_owner = \(context.workerId) AND lease_token = \(context.leaseToken)
          AND lease_expires_at > \(now) FOR UPDATE
        """
    } else {
      query = """
        SELECT recovery_state FROM appview_ingestion_inbox
        WHERE environment = \(context.environment) AND source_generation = \(context.sourceGeneration)
          AND seq = \(context.sequence) AND repo_did = \(context.repoDid) AND status = 'leased'
          AND lease_owner = \(context.workerId) AND lease_token = \(context.leaseToken)
          AND lease_expires_at > \(now) FOR UPDATE
        """
    }
    for try await row in try await connection.query(query, logger: logger) {
      return try row.decode(String?.self)
    }
    throw AppViewIngestionInboxStoreError.staleLease
  }
}
