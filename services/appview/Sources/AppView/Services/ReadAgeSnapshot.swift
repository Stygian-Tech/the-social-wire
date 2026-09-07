import Foundation
import Hummingbird
import ThinAppViewCore

enum ReadAgeSnapshot {
  static func collect(
    page: @Sendable (String?) async throws -> AppViewEntryListResponse
  ) async throws -> [AppViewEntryListItem] {
    var snapshot: [AppViewEntryListItem] = []
    try await forEachPage(page: page) { entries in snapshot.append(contentsOf: entries) }
    return snapshot
  }

  static func forEachPage(
    page: @Sendable (String?) async throws -> AppViewEntryListResponse,
    onPage: ([AppViewEntryListItem]) async throws -> Void
  ) async throws {
    var cursor: String?
    var seenCursors = Set<String>()
    var seenIds = Set<String>()
    repeat {
      try Task.checkCancellation()
      let result = try await page(cursor)
      let entries = result.entries.filter { seenIds.insert($0.entryId).inserted }
      cursor = result.cursor
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw HTTPError(.internalServerError, message: "Feed pagination did not advance")
      }
      try await onPage(entries)
    } while cursor != nil
  }
}
