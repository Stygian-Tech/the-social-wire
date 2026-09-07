import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

struct WireRollupIntegrationFixture {
  let pool: PostgresClient
  let logger: Logger
  let prefix = "rollup-test-\(UUID().uuidString.lowercased())"
  let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

  var store: PostgresWireSignalRollupStore {
    PostgresWireSignalRollupStore(pool: pool, logger: logger)
  }

  func item(_ suffix: String) async throws -> String {
    let key = "\(prefix)-\(suffix)"
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title,
         first_seen_at, last_seen_at, expires_at)
      VALUES (\(key), \("https://example.com/" + key), 'example.com', 'Example',
              'Rollup Test', \(now), \(now), \(now.addingTimeInterval(14 * 86_400)))
      """, logger: logger)
    return key
  }

  func signal(
    _ key: String, actor: String, occurredAt: Date, kind: String = "share",
    collection: String = "app.bsky.feed.post", community: String? = nil,
    expiresAt: Date? = nil
  ) async throws {
    try await pool.query(
      "SELECT ensure_wire_signal_event_partition(\(occurredAt)::date)", logger: logger)
    let eventKey = "\(prefix)-\(UUID().uuidString.lowercased())"
    try await pool.query(
      """
      INSERT INTO wire_signal_events
        (event_key, canonical_key, signal_kind, actor_key_hash, community_key_hash,
         source_uri, occurred_at, expires_at, source_collection, source_action)
      VALUES (\(eventKey), \(key), \(kind), \("actor-hash-for-" + actor), \(community),
              \("at://did:example:test/" + collection + "/" + eventKey), \(occurredAt),
              \(expiresAt ?? now.addingTimeInterval(14 * 86_400)), \(collection), \(kind))
      """, logger: logger)
  }

  func snapshot(_ key: String) async throws -> String? {
    let rows = try await pool.query(
      """
      SELECT jsonb_build_object('data', to_jsonb(rollup), 'tuple', ctid::text,
                                'transaction', xmin::text)::text
      FROM wire_signal_rollups rollup WHERE canonical_key = \(key)
      """, logger: logger)
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }

  func counts(_ key: String) async throws -> [String: Int] {
    let rows = try await pool.query(
      "SELECT to_jsonb(rollup)::text FROM wire_signal_rollups rollup WHERE canonical_key = \(key)",
      logger: logger)
    for try await row in rows {
      let json = try row.decode(String.self)
      let values = try #require(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      return values.compactMapValues { ($0 as? NSNumber)?.intValue }
    }
    return [:]
  }

  func clean() async throws {
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
  }

  static func run(
    _ operation: (WireRollupIntegrationFixture) async throws -> Void
  ) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-rollup-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let fixture = WireRollupIntegrationFixture(pool: pool, logger: logger)
    do {
      try await operation(fixture)
      try await fixture.clean()
    } catch {
      try await fixture.clean()
      throw error
    }
  }
}
