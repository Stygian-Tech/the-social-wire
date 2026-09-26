import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("incremental batches are ordered, bounded and preserve every field across dense and sparse refreshes")
  func incrementalRollupBatchParity() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let prefix = fixture.prefix + "-batch-"
      try await fixture.pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title,
           first_seen_at, last_seen_at, expires_at)
        SELECT \(prefix) || lpad(n::text, 4, '0'),
          'https://example.com/' || \(prefix) || n::text, 'example.com', 'Example', 'Batch',
          \(fixture.now), \(fixture.now), \(fixture.now.addingTimeInterval(14 * 86_400))
        FROM generate_series(1, 1003) n
        """, logger: fixture.logger)
      try await fixture.pool.query(
        "SELECT ensure_wire_signal_event_partition(\(fixture.now)::date)", logger: fixture.logger)
      try await fixture.pool.query(
        """
        INSERT INTO wire_signal_events
          (event_key, canonical_key, signal_kind, actor_key_hash, community_key_hash,
           source_uri, occurred_at, expires_at, source_collection, source_action)
        SELECT \(prefix) || n::text, \(prefix) || lpad(LEAST(n, 1003)::text, 4, '0'),
          CASE n % 3 WHEN 0 THEN 'share' WHEN 1 THEN 'like' ELSE 'repost' END,
          'actor-hash-for-' || (n % 73)::text, 'community-' || (n % 2)::text,
          'at://did:example:batch/app.bsky.feed.post/' || \(prefix) || n::text,
          \(fixture.now), \(fixture.now.addingTimeInterval(14 * 86_400)),
          CASE n % 2 WHEN 0 THEN 'app.bsky.feed.post' ELSE 'network.cosmik.card' END, 'create'
        FROM generate_series(1, 11003) n
        """, logger: fixture.logger)
      // The last selected key is deliberately popular, so the short final
      // batch exercises aggregation rather than merely transport pagination.
      try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
        #expect(try await fixture.store.prepareIncrementalRefresh(connection: connection, asOf: fixture.now))
        var afterKey: String?
        var selected: [String] = []
        while let lastKey = try await fixture.store.selectNextIncrementalBatch(
          connection: connection, afterKey: afterKey
        ) {
          let rows = try await connection.query(
            "SELECT canonical_key FROM wire_signal_rollup_batch ORDER BY canonical_key", logger: fixture.logger)
          var batch: [String] = []
          for try await row in rows { batch.append(try row.decode(String.self)) }
          #expect(batch.count <= 1000)
          #expect(batch.last == lastKey)
          if let afterKey { #expect(batch.first.map { $0 > afterKey } == true) }
          selected.append(contentsOf: batch)
          afterKey = lastKey
        }
        #expect(selected.filter { $0.hasPrefix(prefix) }.count == 1003)
        #expect(Set(selected).count == selected.count)
      }
      let oracle = PostgresWireSignalRollupStore(pool: fixture.pool, logger: fixture.logger)
      for instant in [fixture.now, fixture.now.addingTimeInterval(3_600.001),
                      fixture.now.addingTimeInterval(86_400.001),
                      fixture.now.addingTimeInterval(604_800.001)] {
        try await fixture.store.refresh(asOf: instant)
        let selected = try await batchValues(fixture, prefix: prefix)
        try await oracle.refresh(asOf: instant)
        #expect(try await batchValues(fixture, prefix: prefix) == selected)
        // Restore scheduling after the oracle invalidates its coverage, then
        // revisit the same time without dirty work: unchanged tuples survive.
        try await fixture.store.refresh(asOf: instant)
        let snapshot = try await fixture.snapshot(prefix + "1003")
        try await fixture.store.refresh(asOf: instant)
        #expect(try await fixture.snapshot(prefix + "1003") == snapshot)
      }
    }
  }

  private func batchValues(_ fixture: WireRollupIntegrationFixture, prefix: String) async throws -> String {
    let rows = try await fixture.pool.query(
      """
      SELECT COALESCE(jsonb_agg(to_jsonb(rollup) - 'updated_at' ORDER BY canonical_key), '[]'::jsonb)::text
      FROM wire_signal_rollups rollup WHERE canonical_key LIKE \(prefix + "%")
      """, logger: fixture.logger)
    for try await row in rows { return try row.decode(String.self) }
    return "[]"
  }
}
