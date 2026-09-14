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
    let result = try await ReadAgeSnapshot.matchingIDs(before: Date(timeIntervalSince1970: 200)) { cursor in
      switch cursor {
      case nil: UnreadReadMutationPage(entries: [first], cursor: "empty")
      case "empty": UnreadReadMutationPage(entries: [], cursor: "last")
      default: UnreadReadMutationPage(entries: [first, second], cursor: nil)
      }
    }
    #expect(result == ["first", "second"])
  }

  @Test("publishes deduplicated page batches before requesting the next page")
  func progressiveSnapshots() async throws {
    let first = entry("first")
    let second = entry("second")
    let recorder = PageRecorder()
    try await ReadAgeSnapshot.forEachPage { cursor in
      if cursor == nil { return UnreadReadMutationPage(entries: [first], cursor: "next") }
      #expect(await recorder.snapshots == [["first"]])
      return UnreadReadMutationPage(entries: [first, second], cursor: nil)
    } onPage: { entries in
      await recorder.append(entries.map(\.entryId))
    }
    #expect(await recorder.snapshots == [["first"], ["second"]])
  }

  @Test("a failed later page never emits a completed snapshot")
  func failedPage() async {
    let first = entry("first")
    let recorder = PageRecorder()
    await #expect(throws: HTTPError.self) {
      try await ReadAgeSnapshot.forEachPage { cursor in
        guard cursor == nil else { throw HTTPError(.serviceUnavailable) }
        return UnreadReadMutationPage(entries: [first], cursor: "next")
      } onPage: { entries in
        await recorder.append(entries.map(\.entryId))
      }
    }
    #expect(await recorder.snapshots == [["first"]])
  }

  @Test("rejects both stuck cursors and multi-page cursor cycles")
  func cursorCycles() async {
    await #expect(throws: HTTPError.self) {
      try await ReadAgeSnapshot.matchingIDs(before: Date(timeIntervalSince1970: 200)) { _ in
        UnreadReadMutationPage(entries: [], cursor: "same")
      }
    }
    await #expect(throws: HTTPError.self) {
      try await ReadAgeSnapshot.matchingIDs(before: Date(timeIntervalSince1970: 200)) { cursor in
        UnreadReadMutationPage(entries: [], cursor: cursor == "first" ? "second" : "first")
      }
    }
  }

  @Test("matching IDs scan every page and exclude newer or duplicate entries")
  func matchingIDs() async throws {
    let old = entry("old")
    let recent = UnreadReadMutationEntry(entryId: "recent",
      publishedAt: Date(timeIntervalSince1970: 300),
      feedPositionAt: Date(timeIntervalSince1970: 1), publicationId: "fixture")
    let ids = try await ReadAgeSnapshot.matchingIDs(before: Date(timeIntervalSince1970: 200)) { cursor in
      cursor == nil
        ? UnreadReadMutationPage(entries: [recent], cursor: "next")
        : UnreadReadMutationPage(entries: [old, old], cursor: nil)
    }
    #expect(ids == ["old"])
    await #expect(throws: HTTPError.self) {
      _ = try await ReadAgeSnapshot.matchingIDs(before: Date(timeIntervalSince1970: 200)) { cursor in
        guard cursor == nil else { throw HTTPError(.serviceUnavailable) }
        return UnreadReadMutationPage(entries: [old], cursor: "failed")
      }
    }
  }

  private func entry(_ id: String) -> UnreadReadMutationEntry {
    UnreadReadMutationEntry(entryId: id, publishedAt: Date(timeIntervalSince1970: 100),
      feedPositionAt: Date(timeIntervalSince1970: 100), publicationId: "fixture")
  }
}

private actor PageRecorder {
  private(set) var snapshots: [[String]] = []
  func append(_ ids: [String]) { snapshots.append(ids) }
}
