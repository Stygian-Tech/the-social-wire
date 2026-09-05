import Foundation

public enum ThinAppViewCursor {
  public static func encode(createdAt: Date, uri: String) -> String {
    let iso = ISO8601DateFormatter().string(from: createdAt)
    return "\(iso)|\(uri)"
  }

  public static func decode(_ cursor: String) -> (createdAt: Date, uri: String)? {
    guard let pipe = cursor.firstIndex(of: "|") else { return nil }
    let iso = String(cursor[..<pipe])
    let uri = String(cursor[cursor.index(after: pipe)...])
    guard !uri.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: iso) else { return nil }
    return (date, uri)
  }
}

struct EntryListScanRow {
  let uri: String
  let renderJSON: String
  let createdAt: Date
  let publicationSite: String?
}

struct UnreadSiteCount {
  let site: String?
  let count: Int
}

public enum ThinAppViewQuerySupport {
  static func scanBatchSize(pageLimit: Int, scoped: Bool) -> Int {
    scoped ? max(100, pageLimit + 1) : pageLimit + 1
  }

  /// Builds a filtered entry page after scanning one or more DB batches.
  ///
  /// Scoped feeds filter in memory; when a batch is full but yields fewer than `pageLimit`
  /// matches, `dbHasMore` keeps pagination alive using the last scanned row cursor.
  static func buildFilteredEntryListPage(
    pageLimit: Int,
    matches: [EntryListScanRow],
    lastScannedCreatedAt: Date?,
    lastScannedUri: String?,
    dbHasMore: Bool
  ) -> AppViewEntryListResponse {
    let dedupedMatches = dedupeScanRows(matches)
    let hasFullPage = dedupedMatches.count > pageLimit
    let page = hasFullPage ? Array(dedupedMatches.prefix(pageLimit)) : dedupedMatches
    let items = entryListItems(from: page.map { ($0.uri, $0.renderJSON, $0.createdAt) })

    let nextCursor: String?
    if hasFullPage, let last = page.last {
      nextCursor = ThinAppViewCursor.encode(createdAt: last.createdAt, uri: last.uri)
    } else if dbHasMore,
              let lastScannedCreatedAt,
              let lastScannedUri
    {
      nextCursor = ThinAppViewCursor.encode(
        createdAt: lastScannedCreatedAt,
        uri: lastScannedUri
      )
    } else {
      nextCursor = nil
    }

    return AppViewEntryListResponse(entries: items, cursor: nextCursor)
  }

  static func dedupeScanRows(_ rows: [EntryListScanRow]) -> [EntryListScanRow] {
    var seenEntryIds = Set<String>()
    var seenIdentityKeys = Set<String>()
    var seenTitlePublished = Set<String>()
    var deduped: [EntryListScanRow] = []
    deduped.reserveCapacity(rows.count)
    let decoder = JSONDecoder()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoBasic = ISO8601DateFormatter()

    for row in rows {
      guard seenEntryIds.insert(row.uri).inserted else { continue }

      let identityKeys = RssFeedIdentity.dedupeIdentityKeys(
        forEntryId: row.uri,
        renderJSON: row.renderJSON,
        summary: nil
      )
      if RssFeedIdentity.registersAsDuplicateIdentity(keys: identityKeys, seen: &seenIdentityKeys) {
        if let existingIdx = deduped.firstIndex(where: {
          !RssFeedIdentity.dedupeIdentityKeys(forEntryId: $0.uri, renderJSON: $0.renderJSON, summary: nil)
            .isDisjoint(with: identityKeys)
        }),
           !renderHasThumbnail(deduped[existingIdx].renderJSON),
           renderHasThumbnail(row.renderJSON)
        {
          deduped[existingIdx] = row
        }
        continue
      }

      if identityKeys.isEmpty {
        guard
          let data = row.renderJSON.data(using: .utf8),
          let render = try? decoder.decode(ContentRenderFields.self, from: data)
        else {
          deduped.append(row)
          continue
        }
        let publishedAt = iso.date(from: render.publishedAt)
          ?? isoBasic.date(from: render.publishedAt)
          ?? row.createdAt
        let titleKey =
          "\(render.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(Int(publishedAt.timeIntervalSince1970))"
        guard seenTitlePublished.insert(titleKey).inserted else { continue }
      }

      deduped.append(row)
    }
    return deduped
  }

  static func renderHasThumbnail(_ renderJSON: String) -> Bool {
    guard
      let data = renderJSON.data(using: .utf8),
      let render = try? JSONDecoder().decode(ContentRenderFields.self, from: data)
    else { return false }
    return !(render.thumbnailUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func parseISO8601Date(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    return ISO8601DateFormatter().date(from: raw)
  }

  static func entryListItems(from rows: [(uri: String, renderJSON: String, createdAt: Date)]) -> [AppViewEntryListItem] {
    let decoder = JSONDecoder()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoBasic = ISO8601DateFormatter()

    return rows.compactMap { row in
      guard
        let data = row.renderJSON.data(using: .utf8),
        let render = try? decoder.decode(ContentRenderFields.self, from: data)
      else { return nil }

      let publishedAt = iso.date(from: render.publishedAt)
        ?? isoBasic.date(from: render.publishedAt)
        ?? row.createdAt

      let originalUrl = RssFeedIdentity.originalArticleURL(
        forEntryId: row.uri,
        render: render,
        summary: render.summary
      )

      return AppViewEntryListItem(
        entryId: row.uri,
        title: HtmlTextDecoder.decodePlainText(render.title),
        summary: render.summary.map(HtmlTextDecoder.decodePlainText),
        publishedAt: publishedAt,
        thumbnailUrl: render.thumbnailUrl,
        thumbnailFallbackUrl: nil,
        originalUrl: originalUrl,
        feedPositionAt: row.createdAt
      )
    }
  }

  static func publicationSiteMatches(
    siteField: String?,
    publicationAtUri: String?,
    publicationScopeAtUris: [String] = [],
    publicationSiteUrls: [String] = []
  ) -> Bool {
    RenderFieldExtractor.matchesPublication(
      siteField: siteField,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
  }

  static func requiresPublicationSiteFilter(
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String] = []
  ) -> Bool {
    publicationAtUri != nil || !publicationScopeAtUris.isEmpty || !publicationSiteUrls.isEmpty
  }

  static func countMatchingPublicationSites(
    siteFields: [String?],
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) -> Int {
    siteFields.reduce(into: 0) { count, siteField in
      if publicationSiteMatches(
        siteField: siteField,
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls
      ) {
        count += 1
      }
    }
  }

  static func unreadCountForScope(
    unreadSiteFields: [String?],
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) -> Int {
    let scoped = requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    if !scoped {
      return unreadSiteFields.count
    }
    return countMatchingPublicationSites(
      siteFields: unreadSiteFields,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
  }

  static func unreadCountForScope(
    unreadSiteCounts: [UnreadSiteCount],
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) -> Int {
    let scoped = requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    if !scoped {
      return unreadSiteCounts.reduce(0) { $0 + $1.count }
    }
    return unreadSiteCounts.reduce(into: 0) { total, row in
      if publicationSiteMatches(
        siteField: row.site,
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls
      ) {
        total += row.count
      }
    }
  }

  static func batchUnreadCounts(
    scopes: [PublicationUnreadScope],
    unreadSiteFieldsByAuthor: [String: [String?]]
  ) -> [String: Int] {
    var counts: [String: Int] = [:]
    for scope in scopes {
      let siteFields = unreadSiteFieldsByAuthor[scope.authorDid] ?? []
      let count = unreadCountForScope(
        unreadSiteFields: siteFields,
        publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls
      )
      if count > 0 {
        counts[scope.publicationId] = count
      }
    }
    return counts
  }

  static func batchUnreadCounts(
    scopes: [PublicationUnreadScope],
    unreadSiteCountsByAuthor: [String: [UnreadSiteCount]]
  ) -> [String: Int] {
    var counts: [String: Int] = [:]
    for scope in scopes {
      let siteCounts = unreadSiteCountsByAuthor[scope.authorDid] ?? []
      counts[scope.publicationId] = unreadCountForScope(
        unreadSiteCounts: siteCounts,
        publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls
      )
    }
    return counts
  }
}

extension ContentRenderFields {
  func encodedJSON() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return string
  }
}

public enum ThinAppViewStoreError: Error {
  case encodingFailed
}
