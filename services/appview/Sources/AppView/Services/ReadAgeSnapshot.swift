import Foundation
import Hummingbird
import ThinAppViewCore

enum ReadAgeSnapshot {
  static func collect(
    page: @Sendable (String?) async throws -> AppViewEntryListResponse
  ) async throws -> [AppViewEntryListItem] {
    var cursor: String?
    var seenCursors = Set<String>()
    var seenIds = Set<String>()
    var entries: [AppViewEntryListItem] = []
    repeat {
      try Task.checkCancellation()
      let result = try await page(cursor)
      entries.append(contentsOf: result.entries.filter { seenIds.insert($0.entryId).inserted })
      cursor = result.cursor
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw HTTPError(.internalServerError, message: "Feed pagination did not advance")
      }
    } while cursor != nil
    return entries
  }
}
