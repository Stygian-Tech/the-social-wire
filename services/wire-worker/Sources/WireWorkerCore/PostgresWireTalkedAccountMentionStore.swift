import Foundation
import Logging
import PostgresNIO

struct PostgresWireTalkedAccountMentionStore: WireTalkedAccountMentionStoring {
  let pool: PostgresClient
  let logger: Logger
  private let metadataPruneCursor = WireMetadataPruneCursor()
  private let metadataPruneMaximumBatches: Int
  private let metadataPruneTimeBudget: Duration

  init(
    pool: PostgresClient, logger: Logger,
    metadataPruneMaximumBatches: Int = 20, metadataPruneTimeBudget: Duration = .seconds(2)
  ) {
    self.pool = pool
    self.logger = logger
    self.metadataPruneMaximumBatches = metadataPruneMaximumBatches
    self.metadataPruneTimeBudget = metadataPruneTimeBudget
  }

  func replaceMentions(
    sourceURI: String,
    canonicalKey: String,
    subjectDIDs: [String],
    speakerKeyHash: String,
    occurredAt: Date,
    expiresAt: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(sourceURI), 0))",
        logger: logger
      )
      let newerRows = try await connection.query(
        "SELECT EXISTS(SELECT 1 FROM wire_item_mentions WHERE source_uri = \(sourceURI) AND occurred_at > \(occurredAt))",
        logger: logger
      )
      for try await row in newerRows where try row.decode(Bool.self) { return }

      try await connection.query(
        "DELETE FROM wire_item_mentions WHERE source_uri = \(sourceURI) AND occurred_at <= \(occurredAt)",
        logger: logger
      )
      for subjectDID in Set(subjectDIDs) {
        try await connection.query(
          """
          INSERT INTO wire_item_mentions
            (source_uri, canonical_key, subject_did, speaker_key_hash, occurred_at, expires_at)
          VALUES
            (\(sourceURI), \(canonicalKey), \(subjectDID), \(speakerKeyHash), \(occurredAt), \(expiresAt))
          ON CONFLICT (source_uri, canonical_key, subject_did) DO UPDATE
          SET speaker_key_hash = EXCLUDED.speaker_key_hash,
              occurred_at = EXCLUDED.occurred_at,
              expires_at = EXCLUDED.expires_at
          WHERE wire_item_mentions.occurred_at <= EXCLUDED.occurred_at
          """,
          logger: logger
        )
      }
    }
  }

  func retract(sourceURI: String, through eventTime: Date) async throws {
    try await pool.query(
      "DELETE FROM wire_item_mentions WHERE source_uri = \(sourceURI) AND occurred_at <= \(eventTime)",
      logger: logger
    )
  }

  func removeActor(did: String, actorKeyHash: String) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM wire_item_mentions WHERE subject_did = \(did) OR speaker_key_hash = \(actorKeyHash)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_talked_accounts WHERE subject_did = \(did)",
        logger: logger
      )
    }
  }

  func pruneExpired(asOf: Date) async throws {
    // Mentions/accounts use one batch each. Metadata scans at most 10,000 raw rows across
    // short transactions so protected prefixes do not prevent eventual cleanup.
    let queries: [PostgresQuery] = [
      """
      DELETE FROM wire_item_mentions
      WHERE ctid IN (
        SELECT ctid FROM wire_item_mentions WHERE expires_at <= \(asOf)
        ORDER BY expires_at, source_uri, canonical_key, subject_did
        LIMIT 500 FOR UPDATE SKIP LOCKED
      )
      """,
      """
      DELETE FROM wire_talked_accounts
      WHERE subject_did IN (
        SELECT subject_did FROM wire_talked_accounts WHERE expires_at <= \(asOf)
        ORDER BY expires_at, subject_did LIMIT 500 FOR UPDATE SKIP LOCKED
      )
      """,
    ]
    for query in queries {
      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query("SET LOCAL statement_timeout = '2s'", logger: logger)
        try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: logger)
        try await connection.query(query, logger: logger)
      }
    }
    // The total budget is checked between transactions; a final query can take up to its
    // statement timeout beyond that soft budget. Pool acquisition/commit time is additional.
    let report = try await metadataPruneCursor.run(
      maximumBatches: metadataPruneMaximumBatches, timeBudget: metadataPruneTimeBudget
    ) { position in
      try await pool.withTransaction(logger: logger) { connection in
        try Task.checkCancellation()
        try await connection.query("SET LOCAL statement_timeout = '2s'", logger: logger)
        try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: logger)
        let rows = try await connection.query(
          WireMetadataPruneQuery.make(asOf: asOf, position: position), logger: logger)
        var batch = WireMetadataPruneCursor.Batch(position: nil)
        for try await row in rows {
          let (examined, staleUntil, canonicalKey, deleted) =
            try row.decode((Int64, String?, String?, Int64).self)
          var next: WireMetadataPruneCursor.Position?
          if examined == 500, let staleUntil, let canonicalKey {
            next = .init(staleUntil: staleUntil, canonicalKey: canonicalKey)
          }
          batch = .init(position: next, examined: examined, deleted: deleted)
        }
        try Task.checkCancellation()
        return batch
      }
    }
    if let report {
      let duration = report.duration.components
      logger.info("Wire metadata cleanup pass completed", metadata: [
        "examined_rows": .stringConvertible(report.examined),
        "deleted_rows": .stringConvertible(report.deleted),
        "committed_batches": .stringConvertible(report.batches),
        "wrapped": .stringConvertible(report.wrapped),
        "duration_ms": .stringConvertible(
          Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15),
        "observed_at": .stringConvertible(Date().timeIntervalSince1970),
      ])
    }
  }
}
