import Foundation
import Hummingbird
import ThinAppViewCore

enum ReadAgeSnapshot {
  static func matchingIDs(
    before cutoff: Date,
    page: @Sendable (String?) async throws -> UnreadReadMutationPage
  ) async throws -> [String] {
    var ids: [String] = []
    try await forEachPage(page: page) { entries in
      ids.append(contentsOf: entries.filter { $0.publishedAt < cutoff }.map(\.entryId))
    }
    return ids
  }

  static func forEachPage(
    page: @Sendable (String?) async throws -> UnreadReadMutationPage,
    onPage: ([UnreadReadMutationEntry]) async throws -> Void
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
