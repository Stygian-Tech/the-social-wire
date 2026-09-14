import Foundation
import Logging
import PostgresNIO
import Testing

struct WireSignalPartitionTestFixture: Sendable {
  let pool: PostgresClient
  let logger: Logger
  // Generated identifier only; never constructed from user-controlled input.
  let schema = "wire_partition_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

  func create() async throws {
    try await pool.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"), logger: logger)
    try await pool.withTransaction(logger: logger) { connection in
      try await configure(connection)
      try await connection.query(
        "CREATE TABLE wire_signal_events (occurred_at timestamptz NOT NULL) PARTITION BY RANGE (occurred_at)",
        logger: logger)
    }
  }

  func configure(_ connection: PostgresConnection) async throws {
    try await connection.query(
      "SELECT set_config('search_path', \(schema + ", public"), true)", logger: logger)
    try await connection.query("SET LOCAL TIME ZONE 'Etc/GMT-11'", logger: logger)
    try await connection.query("SET LOCAL statement_timeout = '10s'", logger: logger)
  }

  func verifyPartition() async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await configure(connection)
      let rows = try await connection.query(
        """
        SELECT c.relpersistence::text, COUNT(*) OVER ()::bigint
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'wire_signal_events'::regclass
        """, logger: logger)
      var found = false
      for try await row in rows {
        let state = try row.decode((String, Int64).self)
        #expect(state.0 == "u")
        #expect(state.1 == 1)
        found = true
      }
      #expect(found)
      // Both UTC endpoints inside the day must route correctly even with a
      // non-UTC session. Outside endpoints must be excluded from its bounds.
      try await connection.query(
        """
        INSERT INTO wire_signal_events VALUES
          ('2099-01-02 00:00:00+00'), ('2099-01-02 23:59:59.999999+00')
        """, logger: logger)
      let bounds = try await connection.query(
        """
        SELECT pg_get_expr(c.relpartbound, c.oid)
        FROM pg_class c WHERE c.oid = 'wire_signal_events_20990102'::regclass
        """, logger: logger)
      for try await row in bounds {
        let bound = try row.decode(String.self)
        #expect(bound.contains("2099-01-02 11:00:00+11"))
        #expect(bound.contains("2099-01-03 11:00:00+11"))
      }
    }
  }

  func remove() async throws {
    try await pool.query(
      PostgresQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(schema) CASCADE"), logger: logger)
  }
}
