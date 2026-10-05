import Crypto
import Foundation
@preconcurrency import GRDB
import Logging
import Testing
@testable import ThinAppViewCore

private func sportsKey(_ reference: String) -> String {
  SHA256.hash(data: Data("\(reference)".utf8)).map { String(format: "%02x", $0) }.joined()
}
private extension SQLiteThinAppViewStore {
  func sportsReferences() async throws -> [String] {
    try await db.read { try String.fetchAll($0, sql: "SELECT reference FROM sports_selections ORDER BY reference") }
  }
}
@Test func sportsSelectionValidationAndReplayOrdering() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try SQLiteThinAppViewStore(path: directory.appendingPathComponent("test.sqlite").path, logger: Logger(label: "sports-test"))
  let record: [String: Any] = ["$type": "app.thesocialwire.sports.selection", "action": "follow", "reference": "sp-a"]
  let at = Date(timeIntervalSince1970: 1000)
  let key = sportsKey("sp-a")
  #expect(SportsSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: sportsKey("other"),
    operation: "create", record: record, eventAt: at, repoRev: "001") == nil)
  let create = try #require(SportsSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "create", record: record, eventAt: at, repoRev: "001"))
  let delete = try #require(SportsSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "delete", record: [:], eventAt: at.addingTimeInterval(1), repoRev: "002"))
  try await store.applySportsSelection(create)
  #expect(try await store.sportsReferences() == ["sp-a"])
  try await store.applySportsSelection(delete)
  try await store.applySportsSelection(create)
  #expect(try await store.sportsReferences().isEmpty)
  let recreate = try #require(SportsSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "update", record: record, eventAt: at.addingTimeInterval(1), repoRev: "003"))
  try await store.applySportsSelection(recreate)
  try await store.applySportsSelection(delete)
  #expect(try await store.sportsReferences() == ["sp-a"])
}
@Test func sportsSelectionCollectionIsViewerScoped() {
  #expect(AppViewIngestionScopePolicy.viewerCollections.contains("app.thesocialwire.sports.selection"))
  #expect(!AppViewIngestionScopePolicy.publicationAuthorCollections.contains("app.thesocialwire.sports.selection"))
}

private extension SQLiteThinAppViewStore {
  func seedSportsOnlyViewer(at: Date) async throws {
    try await db.write { database in
      try database.execute(sql: "INSERT INTO sports_selection_sync VALUES (?,?)", arguments: ["did:plc:sports-only", at.timeIntervalSince1970])
      let iso = ISO8601DateFormatter().string(from: at)
      try database.execute(sql: """
        INSERT INTO appview_ingestion_inbox
          (environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,collection,payload,event_time,next_attempt_at,staged_at,updated_at)
        VALUES ('dev','sports-test',1,'jetstream.example','jetstream_v2_seq','commit',
          'did:plc:sports-only','app.thesocialwire.sports.selection','{}',?,?,?,?)
        """, arguments: [iso,iso,iso,iso])
    }
  }
}
@Test func sportsOnlyEnrollmentAdmitsSelectionWithoutReaderSubscription() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try SQLiteThinAppViewStore(path: directory.appendingPathComponent("test.sqlite").path, logger: Logger(label: "sports-test"))
  let at = Date(timeIntervalSince1970: 1000)
  try await store.seedSportsOnlyViewer(at: at)
  let filtered = try await store.filterIngestionInboxOutsideScope(environment: "dev", sourceGeneration: "sports-test",
    policy: AppViewIngestionScopePolicy.version, limit: 10, expiresAt: at.addingTimeInterval(86400), at: at)
  #expect(filtered == 0)
  let claimed = try await store.claimIngestionInbox(environment: "dev", sourceGeneration: "sports-test",
    workerId: "worker", limit: 10, leaseUntil: at.addingTimeInterval(30), at: at)
  #expect(claimed.count == 1)
}

@Test func sportsFollowAndMuteShareIdentity() async throws {
  let at = Date(timeIntervalSince1970: 1000)
  let key = sportsKey("sp-team")
  let follow = try #require(SportsSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "create", record: ["$type": "app.thesocialwire.sports.selection", "action": "follow", "reference": "sp-team"], eventAt: at, repoRev: "001"))
  let mute = try #require(SportsSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "update", record: ["$type": "app.thesocialwire.sports.selection", "action": "mute", "reference": "sp-team"], eventAt: at, repoRev: "002"))
  #expect(follow.recordKey == mute.recordKey)
  #expect(mute.action == "mute")
  #expect(SportsSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "create", record: ["$type": "app.thesocialwire.sports.selection", "action": "subscribe", "reference": "sp-team"], eventAt: at, repoRev: "003") == nil)
}
