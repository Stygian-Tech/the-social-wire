import Foundation
import Logging
import PostgresNIO

struct PostgresWireTalkedAccountProfileStore: WireTalkedAccountProfileStoring {
  let pool: PostgresClient
  let logger: Logger

  func claimDue(limit: Int, asOf: Date) async throws -> [String] {
    let boundedLimit = max(1, min(limit, 100))
    let leaseUntil = asOf.addingTimeInterval(300)
    let rows = try await pool.query(
      """
      WITH eligible AS (
        SELECT mention.subject_did
        FROM wire_item_mentions mention
        JOIN wire_items item ON item.canonical_key = mention.canonical_key
        WHERE mention.expires_at > \(asOf)
          AND item.eligible = TRUE AND item.expires_at > \(asOf)
          AND NOT EXISTS (
            SELECT 1 FROM wire_labels label
            WHERE label.canonical_key = item.canonical_key
              AND label.expires_at > \(asOf)
              AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
          )
        GROUP BY mention.subject_did
        HAVING COUNT(DISTINCT mention.canonical_key) >= 2
           AND COUNT(DISTINCT mention.speaker_key_hash) >= 3
      ), seeded AS (
        INSERT INTO wire_talked_accounts
          (subject_did, status, retry_after, failure_count)
        SELECT subject_did, 'pending', \(asOf), 0 FROM eligible
        ON CONFLICT (subject_did) DO NOTHING
      ), due AS (
        SELECT profile.subject_did
        FROM wire_talked_accounts profile
        JOIN eligible ON eligible.subject_did = profile.subject_did
        WHERE COALESCE(profile.retry_after, profile.expires_at, \(asOf)) <= \(asOf)
        ORDER BY COALESCE(profile.expires_at, '-infinity'::timestamptz), profile.subject_did
        FOR UPDATE OF profile SKIP LOCKED
        LIMIT \(boundedLimit)
      )
      UPDATE wire_talked_accounts profile
      SET status = 'pending', retry_after = \(leaseUntil)
      FROM due
      WHERE profile.subject_did = due.subject_did
      RETURNING profile.subject_did
      """,
      logger: logger
    )
    var result: [String] = []
    for try await row in rows { result.append(try row.decode(String.self)) }
    return result
  }

  func store(_ profile: WireTalkedAccountProfile, asOf: Date) async throws {
    try await pool.query(
      """
      INSERT INTO wire_talked_accounts
        (subject_did, handle, display_name, avatar_url, description,
         status, fetched_at, expires_at, retry_after, failure_count)
      VALUES
        (\(profile.did), \(profile.handle), \(profile.displayName), \(profile.avatarURL),
         \(profile.description), 'fresh', \(asOf), \(asOf.addingTimeInterval(86_400)),
         \(asOf.addingTimeInterval(86_400)), 0)
      ON CONFLICT (subject_did) DO UPDATE SET
        handle = EXCLUDED.handle, display_name = EXCLUDED.display_name,
        avatar_url = EXCLUDED.avatar_url, description = EXCLUDED.description,
        status = 'fresh', fetched_at = EXCLUDED.fetched_at,
        expires_at = EXCLUDED.expires_at, retry_after = EXCLUDED.retry_after,
        failure_count = 0
      """,
      logger: logger
    )
  }

  func markFailure(did: String, asOf: Date) async throws {
    try await pool.query(
      """
      UPDATE wire_talked_accounts
      SET status = CASE WHEN expires_at > \(asOf) THEN 'fresh' ELSE 'failed' END,
          retry_after = \(asOf.addingTimeInterval(3_600)),
          failure_count = failure_count + 1
      WHERE subject_did = \(did)
      """,
      logger: logger
    )
  }
}
