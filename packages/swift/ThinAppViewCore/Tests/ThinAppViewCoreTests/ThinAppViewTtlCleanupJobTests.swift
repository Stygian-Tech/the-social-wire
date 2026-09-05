import Foundation
import GRDB
import Logging
import Testing

@testable import ThinAppViewCore

@Suite("Bounded TTL cleanup")
struct ThinAppViewTtlCleanupJobTests {
  @Test("One sweep drains multiple batches and keeps unexpired content")
  func drainsMultipleBatches() async throws {
    let (path, store) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let now = Date()
    for index in 0..<7 {
      try await store.upsertContentItem(item(index, at: now, expires: now.addingTimeInterval(-10)))
    }
    try await store.upsertContentItem(item(100, at: now, expires: now.addingTimeInterval(3600)))
    let job = ThinAppViewTtlCleanupJob(
      store: store, projectionCache: nil, config: .fromEnvironment([:]),
      environment: "test", batchSize: 2, logger: Logger(label: "ttl.test"))
    #expect(try await job.runOnce() == false)
    let db = try DatabaseQueue(path: path)
    #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM content_items") } == 1)
  }

  @Test("Spent budget signals backlog for prompt rescheduling")
  func reportsBacklog() async throws {
    let (path, store) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let now = Date()
    for index in 0..<5 {
      try await store.upsertContentItem(item(index, at: now, expires: now.addingTimeInterval(-10)))
    }
    let job = ThinAppViewTtlCleanupJob(
      store: store, projectionCache: nil, config: .fromEnvironment([:]),
      environment: "test", batchSize: 2, timeBudget: .zero, logger: Logger(label: "ttl.test"))
    #expect(try await job.runOnce() == true)
    #expect(try await job.runOnce() == true)
    #expect(try await job.runOnce() == false)
  }

  @Test("Cleanup retains pending, leased and unreconciled dead letters across generations")
  func preservesRecoveryState() async throws {
    let (path, store) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try DatabaseQueue(path: path)
    try await db.write { db in
      for (seq, status) in ["pending", "leased", "dead_letter", "applied", "filtered_scope"].enumerated() {
        try db.execute(sql: """
          INSERT INTO appview_ingestion_inbox
            (environment, source_generation, seq, source_host, cursor_kind, event_kind,
             repo_did, payload, event_time, status, next_attempt_at, staged_at, updated_at,
             expires_at, lease_expires_at)
          VALUES ('test', 'old-generation', ?, 'jetstream.test', 'jetstream_v2_seq',
            'commit', 'did:plc:author', '{}', '2020-01-01T00:00:00.000Z', ?,
            '2020-01-01T00:00:00.000Z', '2020-01-01T00:00:00.000Z', '2020-01-01T00:00:00.000Z',
            '2020-01-01T00:00:00.000Z', '2099-01-01T00:00:00.000Z')
          """, arguments: [seq + 1, status])
      }
    }
    let job = ThinAppViewTtlCleanupJob(
      store: store, projectionCache: nil, config: .fromEnvironment([:]),
      environment: "test", batchSize: 1, logger: Logger(label: "ttl.test"))
    #expect(try await job.runOnce() == false)
    let retained = try await db.read { try String.fetchAll($0, sql: "SELECT status FROM appview_ingestion_inbox ORDER BY seq") }
    #expect(retained == ["pending", "leased", "dead_letter"])
  }

  @Test("Identical content avoids writes while expiry and render changes are persisted")
  func unchangedContent() async throws {
    let (path, store) = try makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try DatabaseQueue(path: path)
    try await db.write { db in
      try db.execute(sql: "CREATE TABLE content_updates (count INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO content_updates VALUES (0)")
      try db.execute(sql: "CREATE TRIGGER count_content_updates AFTER UPDATE ON content_items BEGIN UPDATE content_updates SET count = count + 1; END")
    }
    let now = Date()
    func content(indexedOffset: TimeInterval, expiryOffset: TimeInterval, title: String = "Original") -> IndexedContentItem {
      IndexedContentItem(uri: "at://did:plc:author/site.standard.document/one", cid: "cid",
        authorDid: "did:plc:author", collection: "site.standard.document", createdAt: now,
        indexedAt: now.addingTimeInterval(indexedOffset), publicationSite: nil,
        render: ContentRenderFields(title: title, publishedAt: "2026-09-05T00:00:00Z"),
        expiresAt: now.addingTimeInterval(expiryOffset))
    }
    try await store.upsertContentItem(content(indexedOffset: 0, expiryOffset: 3600))
    try await store.upsertContentItem(content(indexedOffset: 1, expiryOffset: 3600))
    #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT count FROM content_updates") } == 0)
    try await store.upsertContentItem(content(indexedOffset: 2, expiryOffset: 7200))
    try await store.upsertContentItem(content(indexedOffset: 3, expiryOffset: 7200, title: "Updated"))
    #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT count FROM content_updates") } == 2)
  }

  private func makeStore() throws -> (String, SQLiteThinAppViewStore) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("ttl-\(UUID()).sqlite").path
    return (path, try SQLiteThinAppViewStore(path: path, logger: Logger(label: "ttl.test")))
  }

  private func item(_ index: Int, at: Date, expires: Date) -> IndexedContentItem {
    IndexedContentItem(uri: "at://did:plc:author/site.standard.document/\(index)",
      cid: "cid-\(index)", authorDid: "did:plc:author", collection: "site.standard.document",
      createdAt: at, indexedAt: at, publicationSite: nil,
      render: ContentRenderFields(title: "Entry \(index)", publishedAt: "2026-09-05T00:00:00Z"), expiresAt: expires)
  }
}
