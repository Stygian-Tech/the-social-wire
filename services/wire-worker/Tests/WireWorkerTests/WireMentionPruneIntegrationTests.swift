import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("mention cleanup bounds every source, skips row locks, and preserves metadata authority")
  func boundedMentionPrune() async throws {
    try await WireRollupIntegrationFixture.run(maximumConnections: 4) { fixture in
      let prefix = fixture.prefix + "-prune-"
      let old = fixture.now.addingTimeInterval(-86_400)
      let future = fixture.now.addingTimeInterval(86_400)
      let store = PostgresWireTalkedAccountMentionStore(pool: fixture.pool, logger: fixture.logger)
      do {
        try await fixture.pool.query(
          """
          INSERT INTO wire_items
            (canonical_key, canonical_url, source_domain, source_name, title,
             first_seen_at, last_seen_at, expires_at, eligible)
          SELECT \(prefix) || n::text, 'https://example.com/prune/' || n::text,
            'example.com', 'Example', 'Prune test', \(old), \(old), \(future), n = 505
          FROM generate_series(1, 505) n
          """, logger: fixture.logger)
        try await fixture.pool.query(
          """
          INSERT INTO wire_item_mentions
            (source_uri, canonical_key, subject_did, speaker_key_hash, occurred_at, expires_at)
          SELECT \(prefix) || n::text, \(prefix) || n::text,
            'did:example:' || \(prefix) || n::text, 'bounded-prune-speaker-hash', \(old),
            CASE WHEN n = 504 THEN \(future) ELSE \(old) END
          FROM generate_series(1, 504) n
          """, logger: fixture.logger)
        try await fixture.pool.query(
          """
          INSERT INTO wire_talked_accounts (subject_did, expires_at)
          SELECT 'did:example:' || \(prefix) || n::text,
            CASE WHEN n = 504 THEN \(future) ELSE \(old) END
          FROM generate_series(1, 504) n
          """, logger: fixture.logger)
        try await fixture.pool.query(
          """
          INSERT INTO wire_link_metadata_cache
            (canonical_key, canonical_url, status, stale_until, retry_after)
          SELECT \(prefix) || n::text, 'https://example.com/prune/' || n::text,
            CASE WHEN n IN (503, 504) THEN 'fetching' ELSE 'stale' END, \(old),
            CASE WHEN n = 504 THEN \(future) ELSE \(fixture.now) END
          FROM generate_series(1, 505) n
          """, logger: fixture.logger)
        try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await connection.query(
            "SELECT 1 FROM wire_item_mentions WHERE source_uri = \(prefix + "1") FOR UPDATE",
            logger: fixture.logger)
          try await connection.query(
            "SELECT 1 FROM wire_talked_accounts WHERE subject_did = \("did:example:" + prefix + "1") FOR UPDATE",
            logger: fixture.logger)
          try await connection.query(
            "SELECT 1 FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "1") FOR UPDATE",
            logger: fixture.logger)
          try await store.pruneExpired(asOf: fixture.now)
          let rows = try await fixture.pool.query(
            """
            SELECT
              (SELECT count(*) FROM wire_item_mentions WHERE source_uri LIKE \(prefix + "%")),
              (SELECT count(*) FROM wire_talked_accounts WHERE subject_did LIKE \("did:example:" + prefix + "%")),
              (SELECT count(*) FROM wire_link_metadata_cache WHERE canonical_key LIKE \(prefix + "%")),
              EXISTS(SELECT 1 FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "1"))
            """, logger: fixture.logger)
          for try await row in rows {
            let (mentions, accounts, metadata, lockedSurvives) = try row.decode((Int64, Int64, Int64, Bool).self)
            #expect(mentions == 4)
            #expect(accounts == 4)
            #expect(metadata == 5)
            #expect(lockedSurvives)
          }
        }
        try await store.pruneExpired(asOf: fixture.now)
        let rows = try await fixture.pool.query(
          """
          SELECT
            (SELECT count(*) FROM wire_item_mentions WHERE source_uri LIKE \(prefix + "%")),
            (SELECT count(*) FROM wire_talked_accounts WHERE subject_did LIKE \("did:example:" + prefix + "%")),
            (SELECT count(*) FROM wire_link_metadata_cache WHERE canonical_key LIKE \(prefix + "%")),
            EXISTS(SELECT 1 FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "504")
              AND status = 'fetching' AND retry_after = \(future)),
            EXISTS(SELECT 1 FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "505"))
          """, logger: fixture.logger)
        for try await row in rows {
          let (mentions, accounts, metadata, leaseSurvives, liveItemSurvives) =
            try row.decode((Int64, Int64, Int64, Bool, Bool).self)
          #expect(mentions == 1)
          #expect(accounts == 1)
          #expect(metadata == 2)
          #expect(leaseSurvives)
          #expect(liveItemSurvives)
        }
        try await fixture.pool.query(
          "DELETE FROM wire_talked_accounts WHERE subject_did LIKE \("did:example:" + prefix + "%")",
          logger: fixture.logger)
      } catch {
        try await fixture.pool.query(
          "DELETE FROM wire_talked_accounts WHERE subject_did LIKE \("did:example:" + prefix + "%")",
          logger: fixture.logger)
        throw error
      }
    }
  }
}
