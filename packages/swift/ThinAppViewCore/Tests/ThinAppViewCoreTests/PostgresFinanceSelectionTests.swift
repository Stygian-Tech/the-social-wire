import Crypto
import Foundation
import PostgresNIO
import Testing
@testable import ThinAppViewCore

@Suite("Postgres Finance selection ordering", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil))
struct PostgresFinanceSelectionTests {
  @Test("deletes survive replay, revision ties order deterministically and completed refresh rejects old unknown records")
  func deletionAndRefreshOrdering() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let viewer = "did:plc:finance-selection-" + UUID().uuidString.lowercased()
      let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
      func mutation(_ operation: String, reference: String = "fin-existing", at: Date, rev: String) throws -> FinanceSelectionMutation {
        let key = SHA256.hash(data: Data("instrument:\(reference)".utf8)).map { String(format: "%02x", $0) }.joined()
        return try #require(FinanceSelectionMutation.parse(viewerDID: viewer, recordKey: key,
          operation: operation, record: ["$type":"app.thesocialwire.finance.selection", "kind":"instrument", "reference":reference],
          eventAt: at, repoRev: rev))
      }
      func references() async throws -> [String] {
        let rows = try await fixture.pool.query("SELECT reference FROM finance_selections WHERE viewer_did=\(viewer) ORDER BY reference", logger: fixture.logger)
        var result: [String] = []
        for try await row in rows { result.append(try row.decode(String.self)) }
        return result
      }
      func cleanup() async throws {
        try await fixture.pool.query("DELETE FROM finance_selections WHERE viewer_did=\(viewer)", logger: fixture.logger)
        try await fixture.pool.query("DELETE FROM finance_selection_versions WHERE viewer_did=\(viewer)", logger: fixture.logger)
        try await fixture.pool.query("DELETE FROM finance_selection_sync WHERE viewer_did=\(viewer)", logger: fixture.logger)
      }
      do {
        let create = try mutation("create", at: now, rev: "001")
        let delete = try mutation("delete", at: now.addingTimeInterval(1), rev: "002")
        try await fixture.store.applyFinanceSelection(create)
        #expect(try await references() == ["fin-existing"])
        try await fixture.store.applyFinanceSelection(delete)
        try await fixture.store.applyFinanceSelection(create)
        #expect(try await references().isEmpty)
        let newerSameTime = try mutation("update", at: now.addingTimeInterval(1), rev: "003")
        try await fixture.store.applyFinanceSelection(newerSameTime)
        try await fixture.store.applyFinanceSelection(delete)
        #expect(try await references() == ["fin-existing"])
        try await fixture.store.applyFinanceSelection(try mutation("delete", at: now.addingTimeInterval(2), rev: "004"))
        #expect(try await references().isEmpty)
        // A complete empty PDS reconciliation establishes a watermark even for keys not seen before.
        try await fixture.pool.query("INSERT INTO finance_selection_sync(viewer_did,synced_at) VALUES (\(viewer),\(now.addingTimeInterval(10)))", logger: fixture.logger)
        try await fixture.store.applyFinanceSelection(try mutation("create", reference: "fin-unknown", at: now.addingTimeInterval(3), rev: "005"))
        #expect(try await references().isEmpty)
        let absent = try await fixture.pool.query("SELECT COUNT(*) FROM finance_selection_versions WHERE viewer_did=\(viewer)", logger: fixture.logger)
        for try await row in absent { #expect(try row.decode(Int64.self) == 1) }
        try await fixture.store.applyFinanceSelection(try mutation("create", reference: "fin-unknown", at: now.addingTimeInterval(11), rev: "006"))
        #expect(try await references() == ["fin-unknown"])
      } catch {
        try await cleanup()
        throw error
      }
      try await cleanup()
    }
  }
}
