import Foundation
import Logging
import PostgresNIO

public actor PostgresThinAppViewStore: ThinAppViewStore {
  private let pool: PostgresClient
  private let logger: Logger

public init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  public func upsertContentItem(_ item: IndexedContentItem) async throws {
    let renderJSON = try item.render.encodedJSON()
    try await pool.query(
      """
      INSERT INTO content_items
        (uri, cid, author_did, collection, created_at, indexed_at, publication_site, render_json, expires_at)
      VALUES
        (\(item.uri), \(item.cid), \(item.authorDid), \(item.collection), \(item.createdAt), \(item.indexedAt), \(item.publicationSite), \(renderJSON)::jsonb, \(item.expiresAt))
      ON CONFLICT (uri) DO UPDATE SET
        cid = EXCLUDED.cid,
        author_did = EXCLUDED.author_did,
        collection = EXCLUDED.collection,
        created_at = EXCLUDED.created_at,
        indexed_at = EXCLUDED.indexed_at,
        publication_site = EXCLUDED.publication_site,
        render_json = EXCLUDED.render_json,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  public func deleteContentItem(uri: String) async throws {
    try await pool.query(
      "DELETE FROM content_items WHERE uri = \(uri)",
      logger: logger
    )
  }

  public func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws {
    try await pool.query(
      """
      INSERT INTO read_marks (viewer_did, subject_uri, created_at)
      VALUES (\(viewerDid), \(subjectUri), \(createdAt))
      ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = EXCLUDED.created_at
      """,
      logger: logger
    )
  }

  public func deleteReadMark(viewerDid: String, subjectUri: String) async throws {
    try await pool.query(
      """
      DELETE FROM read_marks
      WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
      """,
      logger: logger
    )
  }

  public func purgeReadMarks(viewerDid: String) async throws {
    try await pool.query(
      "DELETE FROM read_marks WHERE viewer_did = \(viewerDid)",
      logger: logger
    )
  }

  public func fetchContentItem(uri: String) async throws -> AppViewEntryListItem? {
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.uri, ci.render_json::text, ci.created_at
      FROM content_items ci
      WHERE ci.uri = \(uri) AND ci.expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (uri, renderJSON, createdAt) = try row.decode((String, String, Date).self)
      return ThinAppViewQuerySupport.entryListItems(from: [(uri, renderJSON, createdAt)]).first
    }
    return nil
  }

  public func fetchContentRender(uri: String) async throws -> ContentRenderFields? {
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.render_json::text
      FROM content_items ci
      WHERE ci.uri = \(uri) AND ci.expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    let decoder = JSONDecoder()
    for try await row in rows {
      let renderJSON: String = try row.decode(String.self)
      guard let data = renderJSON.data(using: .utf8) else { return nil }
      return try? decoder.decode(ContentRenderFields.self, from: data)
    }
    return nil
  }

  public func hasReadMark(viewerDid: String, subjectUri: String) async throws -> Bool {
    let rows = try await pool.query(
      """
      SELECT 1 AS present
      FROM read_marks
      WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
      LIMIT 1
      """,
      logger: logger
    )
    for try await _ in rows { return true }
    return false
  }

  public func listEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    let pageLimit = max(1, min(limit, 100))
    let now = Date()
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    let batchSize = ThinAppViewQuerySupport.scanBatchSize(
      pageLimit: pageLimit,
      scoped: scoped
    )
    var dbCursor = cursor.flatMap { ThinAppViewCursor.decode($0) }

    if !scoped {
      let fetched = try await fetchContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        filter: filter,
        cursor: dbCursor,
        limit: batchSize,
        now: now
      )
      return ThinAppViewQuerySupport.buildFilteredEntryListPage(
        pageLimit: pageLimit,
        matches: fetched.map {
          EntryListScanRow(
            uri: $0.uri,
            renderJSON: $0.renderJSON,
            createdAt: $0.createdAt,
            publicationSite: $0.publicationSite
          )
        },
        lastScannedCreatedAt: fetched.last?.createdAt,
        lastScannedUri: fetched.last?.uri,
        dbHasMore: fetched.count == batchSize
      )
    }

    var matches: [EntryListScanRow] = []
    var lastScannedCreatedAt: Date?
    var lastScannedUri: String?
    var dbHasMore = false

    scanLoop: while matches.count < pageLimit + 1 {
      let fetched = try await fetchContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        filter: filter,
        cursor: dbCursor,
        limit: batchSize,
        now: now
      )
      if fetched.isEmpty {
        dbHasMore = false
        break
      }

      dbHasMore = fetched.count == batchSize
      for row in fetched {
        lastScannedCreatedAt = row.createdAt
        lastScannedUri = row.uri
        guard
          ThinAppViewQuerySupport.publicationSiteMatches(
            siteField: row.publicationSite,
            publicationAtUri: publicationAtUri,
            publicationScopeAtUris: publicationScopeAtUris,
            publicationSiteUrls: publicationSiteUrls
          )
        else { continue }

        matches.append(
          EntryListScanRow(
            uri: row.uri,
            renderJSON: row.renderJSON,
            createdAt: row.createdAt,
            publicationSite: row.publicationSite
          )
        )
        if matches.count >= pageLimit + 1 {
          break scanLoop
        }
      }

      if !dbHasMore { break }
      guard let last = fetched.last else { break }
      dbCursor = (last.createdAt, last.uri)
    }

    return ThinAppViewQuerySupport.buildFilteredEntryListPage(
      pageLimit: pageLimit,
      matches: matches,
      lastScannedCreatedAt: lastScannedCreatedAt,
      lastScannedUri: lastScannedUri,
      dbHasMore: dbHasMore
    )
  }

  private func fetchContentBatch(
    viewerDid: String,
    authorDid: String,
    filter: EntryListFilter,
    cursor: (createdAt: Date, uri: String)?,
    limit: Int,
    now: Date
  ) async throws -> [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] {
    let rows: PostgresRowSequence
    switch (filter, cursor) {
    case (.all, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.unread, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.read, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        INNER JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.all, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.unread, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    case (.read, let decoded?):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        INNER JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
          AND (ci.created_at < \(decoded.createdAt) OR (ci.created_at = \(decoded.createdAt) AND ci.uri < \(decoded.uri)))
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    }

    var fetched: [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] = []
    for try await row in rows {
      let (uri, renderJSON, createdAt, publicationSite) = try row.decode(
        (String, String, Date, String?).self
      )
      fetched.append((uri, renderJSON, createdAt, publicationSite))
    }
    return fetched
  }

  public func countUnreadEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> Int {
    let now = Date()
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )

    if !scoped {
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::int
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
        """,
        logger: logger
      )
      for try await row in rows {
        return try row.decode(Int.self)
      }
      return 0
    }

    let rows = try await pool.query(
      """
      SELECT ci.publication_site
      FROM content_items ci
      LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
      WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now) AND rm.subject_uri IS NULL
      """,
      logger: logger
    )
    var siteFields: [String?] = []
    for try await row in rows {
      let site: String? = try row.decode(String?.self)
      siteFields.append(site)
    }
    return ThinAppViewQuerySupport.countMatchingPublicationSites(
      siteFields: siteFields,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
  }

  public func deleteExpiredContent(before: Date) async throws -> Int {
    let rows = try await pool.query(
      "DELETE FROM content_items WHERE expires_at <= \(before) RETURNING uri",
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }

  public func deleteExpiredReadMarks(before: Date) async throws -> Int {
    let rows = try await pool.query(
      "DELETE FROM read_marks WHERE created_at <= \(before) RETURNING subject_uri",
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }

  public func listAuthorDidsForProactiveBackfill(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 500))
    let rows = try await pool.query(
      """
      SELECT author_did
      FROM content_items
      WHERE author_did LIKE 'did:%' AND author_did NOT LIKE 'did:web:%'
      GROUP BY author_did
      ORDER BY MAX(indexed_at) ASC
      LIMIT \(capped)
      """,
      logger: logger
    )
    var authorDids: [String] = []
    for try await row in rows {
      let did: String = try row.decode(String.self)
      authorDids.append(did)
    }
    return authorDids
  }

  public func listRssPublicationSites(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 200))
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT publication_site
      FROM content_items
      WHERE author_did = \(RssFeedLexicons.rssAuthorDid)
        AND publication_site IS NOT NULL
        AND expires_at > \(now)
      GROUP BY publication_site
      ORDER BY MIN(indexed_at) ASC
      LIMIT \(capped)
      """,
      logger: logger
    )
    var sites: [String] = []
    for try await row in rows {
      let site: String = try row.decode(String.self)
      sites.append(site)
    }
    return sites
  }
}
