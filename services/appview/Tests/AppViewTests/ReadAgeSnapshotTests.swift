import Foundation
import Hummingbird
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Read age pagination safety")
struct ReadAgeSnapshotTests {
  @Test("continues through empty filtered pages and deduplicates repeated IDs")
  func emptyPagesAndDuplicateIds() async throws {
    let first = entry("first")
    let second = entry("second")
    let result = try await ReadAgeSnapshot.collect { cursor in
      switch cursor {
      case nil: AppViewEntryListResponse(entries: [first], cursor: "empty")
      case "empty": AppViewEntryListResponse(entries: [], cursor: "last")
      default: AppViewEntryListResponse(entries: [first, second], cursor: nil)
      }
    }
    #expect(result.map(\.entryId) == ["first", "second"])
  }

  @Test("rejects both stuck cursors and multi-page cursor cycles")
  func cursorCycles() async {
    await #expect(throws: HTTPError.self) {
      try await ReadAgeSnapshot.collect { _ in
        AppViewEntryListResponse(entries: [], cursor: "same")
      }
    }
    await #expect(throws: HTTPError.self) {
      try await ReadAgeSnapshot.collect { cursor in
        AppViewEntryListResponse(entries: [], cursor: cursor == "first" ? "second" : "first")
      }
    }
  }

  private func entry(_ id: String) -> AppViewEntryListItem {
    AppViewEntryListItem(entryId: id, title: id, publishedAt: Date(timeIntervalSince1970: 100))
  }
}
