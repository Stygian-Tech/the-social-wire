import Foundation

struct AggregateFeedDatabaseRow: Sendable {
  let uri: String
  let authorDid: String
  let publicationSite: String?
  let createdAt: Date
  let title: String
  let publishedAt: String?
  let summary: String?
  let thumbnailUrl: String?
  let articleUrl: String?
}

enum AggregateFeedQuerySupport {
  static func matchingScope(
    for row: AggregateFeedDatabaseRow,
    scopes: [AppViewPublicationScope]
  ) -> AppViewPublicationScope? {
    scopes.first {
      AppViewUnreadCounterSupport.contentMatchesScope(
        authorDid: row.authorDid,
        publicationSite: row.publicationSite,
        scope: $0
      )
    }
  }

  static func entry(
    from row: AggregateFeedDatabaseRow,
    publicationId: String
  ) -> AppViewEntryListItem {
    let publishedAt = row.publishedAt.flatMap(ThinAppViewQuerySupport.parseISO8601Date)
      ?? row.createdAt
    let render = ContentRenderFields(
      title: row.title,
      publishedAt: row.publishedAt ?? ISO8601DateFormatter().string(from: publishedAt),
      summary: row.summary,
      thumbnailUrl: row.thumbnailUrl,
      articleUrl: row.articleUrl
    )
    return AppViewEntryListItem(
      entryId: row.uri,
      title: HtmlTextDecoder.decodePlainText(row.title),
      summary: row.summary.map(HtmlTextDecoder.decodePlainText),
      publishedAt: publishedAt,
      thumbnailUrl: row.thumbnailUrl,
      originalUrl: RssFeedIdentity.originalArticleURL(
        forEntryId: row.uri,
        render: render,
        summary: row.summary
      ),
      publicationId: publicationId,
      feedPositionAt: row.createdAt
    )
  }

  static func filteredByReadState(
    _ entries: [AppViewEntryListItem],
    states: [String: Bool],
    filter: EntryListFilter
  ) -> [AppViewEntryListItem] {
    entries.compactMap { entry in
      let isRead = states[entry.entryId] ?? false
      switch filter {
      case .all:
        return entry.withReadState(isRead)
      case .unread:
        return isRead ? nil : entry.withReadState(false)
      case .read:
        return isRead ? entry.withReadState(true) : nil
      }
    }
  }

  static func deduplicated(
    _ entries: [AppViewEntryListItem]
  ) -> (entries: [AppViewEntryListItem], duplicatesSuppressed: Int) {
    var seenKeys = Set<String>()
    var result: [AppViewEntryListItem] = []
    result.reserveCapacity(entries.count)

    for entry in entries {
      var keys = RssFeedIdentity.dedupeIdentityKeys(
        forEntryId: entry.entryId,
        renderJSON: nil,
        summary: entry.summary
      )
      if let originalUrl = entry.originalUrl,
         let canonical = RssFeedIdentity.canonicalArticleUrl(originalUrl)
      {
        keys.insert("url:\(canonical)")
      }
      if keys.isEmpty {
        keys.insert("uri:\(entry.entryId)")
      }
      guard seenKeys.isDisjoint(with: keys) else { continue }
      seenKeys.formUnion(keys)
      result.append(entry)
    }

    return (result, entries.count - result.count)
  }

  static func response(
    matches: [AppViewEntryListItem],
    pageLimit: Int,
    lastScanned: (createdAt: Date, uri: String)?,
    databaseHasMore: Bool
  ) -> AppViewEntryListResponse {
    let hasExtraMatch = matches.count > pageLimit
    let entries = Array(matches.prefix(pageLimit))
    let cursor: String?
    if hasExtraMatch, let last = entries.last {
      cursor = ThinAppViewCursor.encode(createdAt: last.feedPositionAt, uri: last.entryId)
    } else if databaseHasMore, let lastScanned {
      cursor = ThinAppViewCursor.encode(createdAt: lastScanned.createdAt, uri: lastScanned.uri)
    } else {
      cursor = nil
    }
    return AppViewEntryListResponse(entries: entries, cursor: cursor)
  }
}
