import Foundation
@preconcurrency import GRDB
import Logging
import Testing

@testable import OperationsCore

struct SQLiteIngestionHealthTests {
  @Test("SQLite live health preserves actionable counts without terminal history or other generations")
  func actionableHealth() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString).sqlite").path
    defer { for file in [path, path + "-wal", path + "-shm"] { try? FileManager.default.removeItem(atPath: file) } }
    let store = try SQLiteOperationsStore(path: path, environment: "test", logger: Logger(label: "health.tests"))
    let database = try DatabaseQueue(path: path)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stamp = "2027-01-15T08:00:00.000Z"
    try await database.write { db in
      for generation in ["active", "retired"] {
        for (index, status) in ["pending", "leased", "retry", "applied", "filtered_scope", "dead_letter", "dead_letter"].enumerated() {
          try db.execute(sql: """
            INSERT INTO appview_ingestion_inbox
              (environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,
               staged_at,updated_at,next_attempt_at,lease_owner,lease_token,lease_expires_at,applied_at,
               dead_lettered_at,reconciled_at,filtered_scope_policy,filtered_scope_at)
            VALUES ('test',?,?,'test','jetstream_v2_seq','commit','did:plc:test','{}',?,?,?,?,'2099-01-01T00:00:00Z',
              'owner','token','2099-01-01T00:00:00Z',?,?,?,?,?)
            """, arguments: [generation, index, stamp, status, stamp, stamp,
              status == "applied" ? stamp : nil, status == "dead_letter" ? stamp : nil,
              index == 6 ? stamp : nil, status == "filtered_scope" ? "test" : nil,
              status == "filtered_scope" ? stamp : nil])
        }
      }
    }
    let census = try await store.fetchIngestionDurabilitySnapshot(at: now)
    let health = try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now)
    #expect(health.pending == 1 && health.leased == 1 && health.retrying == 1 && health.deadLetters == 1)
    #expect(health.oldestPendingAt == census.inboxBySourceGeneration["active"]?.oldestPendingAt)
    #expect(health.checkpoint == nil && census.inbox.total == 14)
    let missing = try await store.fetchIngestionGenerationHealth(sourceGeneration: "missing", at: now)
    #expect(missing.pending == 0 && missing.deadLetters == 0 && missing.oldestPendingAt == nil)
  }
}
