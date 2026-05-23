import Foundation

public enum ThinAppViewCursor {
  static func encode(createdAt: Date, uri: String) -> String {
    let iso = ISO8601DateFormatter().string(from: createdAt)
    return "\(iso)|\(uri)"
  }

  static func decode(_ cursor: String) -> (createdAt: Date, uri: String)? {
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
    let hasFullPage = matches.count > pageLimit
    let page = hasFullPage ? Array(matches.prefix(pageLimit)) : matches
    let items = entryListItems(
      from: page.map { ($0.uri, $0.renderJSON, $0.createdAt) }
    )

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
  public static func parseISO8601Date(_ raw: String) -> Date? {
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

      return AppViewEntryListItem(
        entryId: row.uri,
        title: render.title,
        summary: render.summary,
        publishedAt: publishedAt,
        thumbnailUrl: render.thumbnailUrl,
        thumbnailFallbackUrl: nil
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
}

extension ContentRenderFields {
  func encodedJSON() throws -> String {
    let data = try JSONEncoder().encode(self)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return string
  }
}

public enum ThinAppViewStoreError: Error {
  case encodingFailed
}
