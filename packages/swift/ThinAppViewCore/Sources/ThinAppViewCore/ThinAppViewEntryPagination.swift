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
    return RssFeedIdentity.dedupeEntryListItems(merged)
  }

  public struct AggregateStepResult: Sendable {
    public let merged: [AppViewEntryListItem]
    public let responseCursor: String?
    public let completed: Bool
    public let nextFetchCursor: String?

    public init(
      merged: [AppViewEntryListItem],
      responseCursor: String?,
      completed: Bool,
      nextFetchCursor: String?
    ) {
      self.merged = merged
      self.responseCursor = responseCursor
      self.completed = completed
      self.nextFetchCursor = nextFetchCursor
    }
  }

  /// Incorporates one fetched page into a running aggregate (actor-safe; no escaping closure).
  public static func step(
    merged: [AppViewEntryListItem],
    page: AppViewEntryListResponse,
    cappedMax: Int
  ) -> AggregateStepResult {
    if page.entries.isEmpty {
      return AggregateStepResult(
        merged: merged,
        responseCursor: nil,
        completed: true,
        nextFetchCursor: nil
      )
    }

    var merged = mergeEntries(existing: merged, newPage: page.entries)

    if merged.count >= cappedMax {
      let hadOverflow = merged.count > cappedMax
      merged = Array(merged.prefix(cappedMax))
      let responseCursor: String?
      if hadOverflow || page.cursor != nil, let last = merged.last {
        responseCursor = ThinAppViewCursor.encode(createdAt: last.publishedAt, uri: last.entryId)
      } else {
        responseCursor = nil
      }
      return AggregateStepResult(
        merged: merged,
        responseCursor: responseCursor,
        completed: true,
        nextFetchCursor: nil
      )
    }

    guard let pageCursor = page.cursor, !pageCursor.isEmpty else {
      return AggregateStepResult(
        merged: merged,
        responseCursor: nil,
        completed: true,
        nextFetchCursor: nil
      )
    }

    return AggregateStepResult(
      merged: merged,
      responseCursor: nil,
      completed: false,
      nextFetchCursor: pageCursor
    )
  }

  /// Walks AppView entry pages until `maxEntries` is reached or the timeline is exhausted.
  public static func aggregate(
    maxEntries: Int,
    fetchPage: @Sendable (String?) async throws -> AppViewEntryListResponse
  ) async throws -> AppViewEntryListResponse {
    let cappedMax = max(1, min(maxEntries, maxAggregateEntries))

    var merged: [AppViewEntryListItem] = []
    var cursor: String?

    while true {
      let page = try await fetchPage(cursor)
      let stepResult = step(merged: merged, page: page, cappedMax: cappedMax)
      merged = stepResult.merged
      if stepResult.completed {
        return AppViewEntryListResponse(entries: merged, cursor: stepResult.responseCursor)
      }
      cursor = stepResult.nextFetchCursor
    }
  }
}
