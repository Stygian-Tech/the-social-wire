import Foundation
@preconcurrency import GRDB
import Logging
import Testing

@testable import OperationsCore

@Suite("Operations inbox retention SQLite")
struct SQLiteInboxRetentionTests {
  @Test("expired recovery work survives while completed work expires in bounded batches")
  func protectedRecoveryWork() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let store = try SQLiteOperationsStore(path: path.path, environment: "prod",
      logger: Logger(label: "operations-inbox-retention.tests"))
    let cutoff = "1970-01-02T00:00:00.000Z"
    try await store.db.write { db in
      for (seq, status) in [(1, "pending"), (2, "pending"), (3, "retry"), (4, "leased"),
        (5, "leased"), (6, "dead_letter"), (7, "applied"), (8, "filtered_scope"),
        (9, "dead_letter"), (10, "applied"), (11, "applied"), (12, "applied"), (13, "applied")] {
        try db.execute(sql: """
          INSERT INTO appview_ingestion_inbox
            (environment, source_generation, seq, source_host, cursor_kind, event_kind,
             repo_did, payload, event_time, status, lease_owner, lease_token, lease_expires_at,
             applied_at, dead_lettered_at, reconciled_at, expires_at,
             filtered_scope_policy, filtered_scope_at, staged_at, updated_at)
          VALUES (?, 'fixture', ?, 'fixture', 'jetstream_v2_seq', 'commit', 'did:plc:test',
            '{}', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """, arguments: [seq == 13 ? "dev" : "prod", seq, cutoff, status,
            status == "leased" ? "worker" : nil, status == "leased" ? "token" : nil,
            status == "leased" ? (seq == 4 ? "1970-01-03T00:00:00.000Z" : "1970-01-01T00:00:00.000Z") : nil,
            status == "applied" ? cutoff : nil, status == "dead_letter" ? cutoff : nil,
            seq == 9 ? cutoff : nil,
            [1, 12].contains(seq) ? nil : (seq == 10 ? "1970-01-03T00:00:00.000Z"
              : (seq == 11 ? cutoff : "1970-01-01T23:59:\(40 + seq).000Z")),
            status == "filtered_scope" ? "test-policy" : nil,
            status == "filtered_scope" ? cutoff : nil, cutoff, cutoff])
      }
    }
    #expect(try await store.cleanupExpired(at: Date(timeIntervalSince1970: 86_400), batchSize: 2) == 2)
    #expect(try await retained(store) == [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13])
    #expect(try await store.cleanupExpired(at: Date(timeIntervalSince1970: 86_400), batchSize: 2) == 2)
    #expect(try await retained(store) == [1, 2, 3, 4, 5, 6, 10, 12, 13])
    #expect(try await store.cleanupExpired(at: Date(timeIntervalSince1970: 86_400), batchSize: 2) == 0)
  }

  private func retained(_ store: SQLiteOperationsStore) async throws -> [Int64] {
    try await store.db.read { db in
      try Int64.fetchAll(db, sql: "SELECT seq FROM appview_ingestion_inbox ORDER BY seq")
    }
  }
}
