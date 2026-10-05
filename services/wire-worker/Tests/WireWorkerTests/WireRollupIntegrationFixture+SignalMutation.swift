import Foundation
import PostgresNIO
import Testing

extension WireRollupIntegrationFixture {
  func insertOrderedSignal(
    _ key: String, source: String, event: String, occurredAt: Date,
    on connection: PostgresConnection
  ) async throws {
    _ = try await connection.query(
      """
      SELECT public.wire_insert_signal(
        \(event), \("transport:" + event), \(key), 'like', 'ordered-signal-actor',
        \(source), 'app.bsky.feed.like', \(occurredAt), \(occurredAt.addingTimeInterval(86_400)))
      """, logger: logger).collect()
  }

  func insertOrderedSignal(_ key: String, source: String, event: String, occurredAt: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await insertOrderedSignal(key, source: source, event: event, occurredAt: occurredAt, on: connection)
    }
  }

  func orderedSignalFacts() async throws -> [String] {
    let rows = try await pool.query(
      """
      SELECT (to_jsonb(signal) - ARRAY['id', 'ingested_at'])::text
      FROM wire_signal_events signal WHERE canonical_key LIKE \(prefix + "%")
      ORDER BY canonical_key, event_key
      """, logger: logger)
    var result: [String] = []
    for try await row in rows { result.append(try row.decode(String.self)) }
    return result
  }

  func orderedSignalHints() async throws -> [String] {
    let rows = try await pool.query(
      """
      SELECT to_jsonb(hint)::text FROM wire_signal_rollup_dirty hint
      WHERE canonical_key LIKE \(prefix + "%") ORDER BY canonical_key, shard
      """, logger: logger)
    var result: [String] = []
    for try await row in rows { result.append(try row.decode(String.self)) }
    return result
  }
}
