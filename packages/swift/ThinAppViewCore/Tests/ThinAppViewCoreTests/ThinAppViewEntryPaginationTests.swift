import Foundation
import Testing
import ThinAppViewCore

@Suite("ThinAppViewEntryPagination")
struct ThinAppViewEntryPaginationTests {
  private static let publishedAt = Date(timeIntervalSince1970: 1_704_067_200)

  private func entry(_ id: String) -> AppViewEntryListItem {
    AppViewEntryListItem(
      entryId: id,
      title: id,
      publishedAt: Self.publishedAt
    )
  }

  @Test("mergeEntries deduplicates by entryId")
  func mergeEntries() {
    let existing = [entry("a"), entry("b")]
    let merged = ThinAppViewEntryPagination.mergeEntries(
      existing: existing,
      newPage: [entry("b"), entry("c")]
    )
    #expect(merged.map(\.entryId) == ["a", "b", "c"])
  }

  @Test("aggregate stops at maxEntries and preserves next cursor")
  func aggregateCapsWithCursor() async throws {
    var calls = 0
    let response = try await ThinAppViewEntryPagination.aggregate(
      maxEntries: 3
    ) { cursor in
      calls += 1
      if cursor == nil {
        return AppViewEntryListResponse(
          entries: [entry("1"), entry("2")],
          cursor: "page-2"
        )
      }
      return AppViewEntryListResponse(
        entries: [entry("3"), entry("4")],
        cursor: "page-3"
      )
    }

    #expect(calls == 2)
    #expect(response.entries.map(\.entryId) == ["1", "2", "3"])
    #expect(response.cursor == "page-3")
  }

  @Test("aggregate clears cursor when timeline is exhausted")
  func aggregateExhausted() async throws {
    let response = try await ThinAppViewEntryPagination.aggregate(
      maxEntries: 10
    ) { cursor in
      if cursor == nil {
        return AppViewEntryListResponse(entries: [entry("1"), entry("2")], cursor: nil)
      }
      Issue.record("Unexpected extra page fetch")
      return AppViewEntryListResponse(entries: [], cursor: nil)
    }

    #expect(response.entries.map(\.entryId) == ["1", "2"])
    #expect(response.cursor == nil)
  }
}
