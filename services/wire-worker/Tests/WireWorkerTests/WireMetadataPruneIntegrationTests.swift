import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("metadata cleanup progresses through protected pages and wraps for newly eligible cleanup")
  func metadataPruneProtectedPrefix() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      try await seedMetadataPrune(fixture, count: 1_100, protected: 1_000)
      let store = PostgresWireTalkedAccountMentionStore(
        pool: fixture.pool, logger: fixture.logger, metadataPruneMaximumBatches: 1)
      for _ in 0..<2 {
        try await store.pruneExpired(asOf: fixture.now)
        #expect(try await metadataPruneCount(fixture) == 1_100)
      }
      try await store.pruneExpired(asOf: fixture.now)
      #expect(try await metadataPruneCount(fixture) == 1_000)
      try await fixture.pool.query(
        "UPDATE wire_items SET eligible = false WHERE canonical_key = \(fixture.prefix + "-000001")",
        logger: fixture.logger)
      try await store.pruneExpired(asOf: fixture.now)
      #expect(try await metadataPruneCount(fixture) == 999)
    }
  }

  @Test("metadata cleanup bounds a fully locked prefix and revisits it after wrap")
  func metadataPruneLockedPrefix() async throws {
    try await WireRollupIntegrationFixture.run(maximumConnections: 4) { fixture in
      try await seedMetadataPrune(fixture, count: 501, protected: 0)
      let store = PostgresWireTalkedAccountMentionStore(
        pool: fixture.pool, logger: fixture.logger, metadataPruneMaximumBatches: 1)
      try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
        try await connection.query(
          """
          SELECT canonical_key FROM wire_link_metadata_cache
          WHERE canonical_key LIKE \(fixture.prefix + "%")
          ORDER BY stale_until, canonical_key LIMIT 500 FOR UPDATE
          """, logger: fixture.logger)
        try await store.pruneExpired(asOf: fixture.now)
        #expect(try await metadataPruneCount(fixture) == 501)
        try await store.pruneExpired(asOf: fixture.now)
        #expect(try await metadataPruneCount(fixture) == 500)
      }
      try await store.pruneExpired(asOf: fixture.now)
      #expect(try await metadataPruneCount(fixture) == 0)
    }
  }

  @Test("metadata deletion rollback and cancellation preserve both rows and cursor")
  func metadataPruneRollback() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      try await seedMetadataPrune(fixture, count: 501, protected: 0)
      let cursor = WireMetadataPruneCursor()
      await #expect(throws: (any Error).self) {
        try await cursor.run(maximumBatches: 1) { position in
          #expect(position == nil)
          return try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
            _ = try await metadataPruneBatch(fixture, connection: connection, position: position)
            // A failing statement after DELETE exercises actual PostgreSQL rollback.
            try await connection.query("SELECT 1 / 0", logger: fixture.logger)
            return nil
          }
        }
      }
      #expect(try await metadataPruneCount(fixture) == 501)
      let cancellation = Task {
        try await cursor.run(maximumBatches: 1) { position in
          #expect(position == nil)
          return try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
            _ = try await metadataPruneBatch(fixture, connection: connection, position: position)
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
            return nil
          }
        }
      }
      await #expect(throws: (any Error).self) { try await cancellation.value }
      #expect(try await metadataPruneCount(fixture) == 501)
      try await cursor.run(maximumBatches: 1) { position in
        #expect(position == nil)
        return try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await metadataPruneBatch(fixture, connection: connection, position: position)
        }
      }
      #expect(try await metadataPruneCount(fixture) == 1)
    }
  }

  private func seedMetadataPrune(
    _ fixture: WireRollupIntegrationFixture, count: Int, protected: Int
  ) async throws {
    try await fixture.pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title,
         first_seen_at, last_seen_at, expires_at, eligible)
      SELECT \(fixture.prefix) || '-' || lpad(n::text, 6, '0'), 'https://example.com/' || n,
        'example.com', 'Example', 'Cleanup', \(fixture.now), \(fixture.now),
        \(fixture.now.addingTimeInterval(86_400)), n <= \(protected)
      FROM generate_series(1, \(count)) n
      """, logger: fixture.logger)
    try await fixture.pool.query(
      """
      INSERT INTO wire_link_metadata_cache (canonical_key, canonical_url, status, stale_until)
      SELECT canonical_key, canonical_url, 'stale', \(fixture.now.addingTimeInterval(-86_400))
      FROM wire_items WHERE canonical_key LIKE \(fixture.prefix + "%")
      """, logger: fixture.logger)
  }

  private func metadataPruneCount(_ fixture: WireRollupIntegrationFixture) async throws -> Int64 {
    let rows = try await fixture.pool.query(
      "SELECT count(*) FROM wire_link_metadata_cache WHERE canonical_key LIKE \(fixture.prefix + "%")",
      logger: fixture.logger)
    for try await row in rows { return try row.decode(Int64.self) }
    return -1
  }

  private func metadataPruneBatch(
    _ fixture: WireRollupIntegrationFixture, connection: PostgresConnection,
    position: WireMetadataPruneCursor.Position?
  ) async throws -> WireMetadataPruneCursor.Position? {
    let rows = try await connection.query(
      WireMetadataPruneQuery.make(asOf: fixture.now, position: position), logger: fixture.logger)
    for try await row in rows {
      let (count, staleUntil, key) = try row.decode((Int64, String?, String?).self)
      if count == 500, let staleUntil, let key {
        return .init(staleUntil: staleUntil, canonicalKey: key)
      }
    }
    return nil
  }
}
