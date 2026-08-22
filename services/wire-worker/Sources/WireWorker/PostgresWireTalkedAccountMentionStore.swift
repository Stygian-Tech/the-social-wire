import Foundation
import Logging
import PostgresNIO

struct PostgresWireTalkedAccountMentionStore: WireTalkedAccountMentionStoring {
  let pool: PostgresClient
  let logger: Logger

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
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "DELETE FROM wire_item_mentions WHERE expires_at <= \(asOf)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_talked_accounts WHERE expires_at <= \(asOf)",
        logger: logger
      )
      try await connection.query(
        "DELETE FROM wire_link_metadata_cache WHERE stale_until IS NOT NULL AND stale_until <= \(asOf)",
        logger: logger
      )
    }
  }
}
