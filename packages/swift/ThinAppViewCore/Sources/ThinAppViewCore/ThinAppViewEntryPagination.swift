import Foundation

/// Shared cursor pagination helpers for AppView entry timelines.
public enum ThinAppViewEntryPagination {
  public static let defaultPageLimit = 50
  public static let maxAggregateEntries = 500

  public static func mergeEntries(
    existing: [AppViewEntryListItem],
    newPage: [AppViewEntryListItem]
  ) -> [AppViewEntryListItem] {
    guard !newPage.isEmpty else { return existing }
    var seen = Set(existing.map(\.entryId))
    var merged = existing
    merged.reserveCapacity(existing.count + newPage.count)
    for item in newPage where seen.insert(item.entryId).inserted {
      merged.append(item)
    }
    return merged
  }

  /// Walks AppView entry pages until `maxEntries` is reached or the timeline is exhausted.
  public static func aggregate(
    maxEntries: Int,
    fetchPage: (String?) async throws -> AppViewEntryListResponse
  ) async throws -> AppViewEntryListResponse {
    let cappedMax = max(1, min(maxEntries, maxAggregateEntries))

    var merged: [AppViewEntryListItem] = []
    var cursor: String?
    var nextCursor: String?

    while merged.count < cappedMax {
      let page = try await fetchPage(cursor)
      if page.entries.isEmpty {
        nextCursor = nil
        break
      }

      merged = mergeEntries(existing: merged, newPage: page.entries)

      if merged.count >= cappedMax {
        nextCursor = page.cursor
        break
      }

      guard let pageCursor = page.cursor, !pageCursor.isEmpty else {
        nextCursor = nil
        break
      }
      cursor = pageCursor
    }

    if merged.count > cappedMax {
      merged = Array(merged.prefix(cappedMax))
    }

    return AppViewEntryListResponse(entries: merged, cursor: nextCursor)
  }
}
