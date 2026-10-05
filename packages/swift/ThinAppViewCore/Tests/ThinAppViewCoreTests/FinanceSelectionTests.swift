import Crypto
import Foundation
@preconcurrency import GRDB
import Logging
import Testing
@testable import ThinAppViewCore

private func financeKey(_ reference: String) -> String {
  SHA256.hash(data: Data("instrument:\(reference)".utf8)).map { String(format: "%02x", $0) }.joined()
}
private extension SQLiteThinAppViewStore {
  func financeReferences() async throws -> [String] {
    try await db.read { try String.fetchAll($0, sql: "SELECT reference FROM finance_selections ORDER BY reference") }
  }
}
@Test func financeSelectionValidationAndReplayOrdering() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try SQLiteThinAppViewStore(path: directory.appendingPathComponent("test.sqlite").path, logger: Logger(label: "finance-test"))
  let record: [String: Any] = ["$type": "app.thesocialwire.finance.selection", "kind": "instrument", "reference": "fin-a"]
  let at = Date(timeIntervalSince1970: 1000)
  let key = financeKey("fin-a")
  #expect(FinanceSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: financeKey("other"),
    operation: "create", record: record, eventAt: at, repoRev: "001") == nil)
  let create = try #require(FinanceSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "create", record: record, eventAt: at, repoRev: "001"))
  let delete = try #require(FinanceSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "delete", record: [:], eventAt: at.addingTimeInterval(1), repoRev: "002"))
  try await store.applyFinanceSelection(create)
  #expect(try await store.financeReferences() == ["fin-a"])
  try await store.applyFinanceSelection(delete)
  try await store.applyFinanceSelection(create)
  #expect(try await store.financeReferences().isEmpty)
  let recreate = try #require(FinanceSelectionMutation.parse(viewerDID: "did:plc:test", recordKey: key,
    operation: "update", record: record, eventAt: at.addingTimeInterval(1), repoRev: "003"))
  try await store.applyFinanceSelection(recreate)
  try await store.applyFinanceSelection(delete)
  #expect(try await store.financeReferences() == ["fin-a"])
}
@Test func selectionCollectionIsViewerScoped() {
  #expect(AppViewIngestionScopePolicy.viewerCollections.contains("app.thesocialwire.finance.selection"))
  #expect(!AppViewIngestionScopePolicy.publicationAuthorCollections.contains("app.thesocialwire.finance.selection"))
}

private extension SQLiteThinAppViewStore {
  func seedFinanceOnlyViewer(at: Date) async throws {
    try await db.write { database in
      try database.execute(sql: "INSERT INTO finance_selection_sync VALUES (?,?)", arguments: ["did:plc:finance-only", at.timeIntervalSince1970])
      let iso = ISO8601DateFormatter().string(from: at)
      try database.execute(sql: """
        INSERT INTO appview_ingestion_inbox
          (environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,collection,payload,event_time,next_attempt_at,staged_at,updated_at)
        VALUES ('dev','finance-test',1,'jetstream.example','jetstream_v2_seq','commit',
          'did:plc:finance-only','app.thesocialwire.finance.selection','{}',?,?,?,?)
        """, arguments: [iso,iso,iso,iso])
    }
  }
}
@Test func financeOnlyEnrollmentAdmitsSelectionWithoutReaderSubscription() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try SQLiteThinAppViewStore(path: directory.appendingPathComponent("test.sqlite").path, logger: Logger(label: "finance-test"))
  let at = Date(timeIntervalSince1970: 1000)
  try await store.seedFinanceOnlyViewer(at: at)
  let filtered = try await store.filterIngestionInboxOutsideScope(environment: "dev", sourceGeneration: "finance-test",
    policy: AppViewIngestionScopePolicy.version, limit: 10, expiresAt: at.addingTimeInterval(86400), at: at)
  #expect(filtered == 0)
  let claimed = try await store.claimIngestionInbox(environment: "dev", sourceGeneration: "finance-test",
    workerId: "worker", limit: 10, leaseUntil: at.addingTimeInterval(30), at: at)
  #expect(claimed.count == 1)
}
