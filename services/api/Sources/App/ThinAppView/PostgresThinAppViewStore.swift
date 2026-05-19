import Foundation
import Logging
import PostgresNIO

actor PostgresThinAppViewStore: ThinAppViewStore {
  private let pool: PostgresClient
  private let logger: Logger

  init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  func upsertContentItem(_ item: IndexedContentItem) async throws {
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

  func deleteContentItem(uri: String) async throws {
    try await pool.query(
      "DELETE FROM content_items WHERE uri = \(uri)",
      logger: logger
    )
  }

  func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws {
    try await pool.query(
      """
      INSERT INTO read_marks (viewer_did, subject_uri, created_at)
      VALUES (\(viewerDid), \(subjectUri), \(createdAt))
      ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = EXCLUDED.created_at
      """,
      logger: logger
    )
  }

  func deleteReadMark(viewerDid: String, subjectUri: String) async throws {
    try await pool.query(
      """
      DELETE FROM read_marks
      WHERE viewer_did = \(viewerDid) AND subject_uri = \(subjectUri)
      """,
      logger: logger
    )
  }

  func purgeReadMarks(viewerDid: String) async throws {
    try await pool.query(
      "DELETE FROM read_marks WHERE viewer_did = \(viewerDid)",
      logger: logger
    )
  }

  func listEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    let pageLimit = max(1, min(limit, 100))
    let now = Date()
    let fetchLimit = publicationAtUri == nil ? pageLimit + 1 : (pageLimit + 1) * 4
    let decodedCursor = cursor.flatMap { ThinAppViewCursor.decode($0) }

    let rows: PostgresRowSequence
    switch (filter, decodedCursor) {
    case (.all, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid) AND ci.expires_at > \(now)
        ORDER BY ci.created_at DESC, ci.uri DESC
        LIMIT \(fetchLimit)
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
        LIMIT \(fetchLimit)
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
        LIMIT \(fetchLimit)
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
        LIMIT \(fetchLimit)
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
        LIMIT \(fetchLimit)
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
        LIMIT \(fetchLimit)
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

    let filtered = fetched.filter { row in
      ThinAppViewQuerySupport.publicationSiteMatches(
        siteField: row.publicationSite,
        publicationAtUri: publicationAtUri
      )
    }

    let hasMore = filtered.count > pageLimit
    let page = hasMore ? Array(filtered.prefix(pageLimit)) : filtered
    let items = ThinAppViewQuerySupport.entryListItems(
      from: page.map { ($0.uri, $0.renderJSON, $0.createdAt) }
    )

    let nextCursor: String?
    if hasMore, let last = page.last {
      nextCursor = ThinAppViewCursor.encode(createdAt: last.createdAt, uri: last.uri)
    } else {
      nextCursor = nil
    }

    return AppViewEntryListResponse(entries: items, cursor: nextCursor)
  }

  func deleteExpiredContent(before: Date) async throws -> Int {
    let rows = try await pool.query(
      "DELETE FROM content_items WHERE expires_at <= \(before) RETURNING uri",
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }

  func deleteExpiredReadMarks(before: Date) async throws -> Int {
    let rows = try await pool.query(
      "DELETE FROM read_marks WHERE created_at <= \(before) RETURNING subject_uri",
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }
}
