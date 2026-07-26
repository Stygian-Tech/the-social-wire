import Foundation
import Logging
import OperationsCore
import PostgresNIO

public actor PostgresThinAppViewStore: ThinAppViewStore {
  private let pool: PostgresClient
  private let logger: Logger

public init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  public func ping() async throws {
    let rows = try await pool.query("SELECT 1", logger: logger)
    for try await _ in rows { return }
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

  public func deleteContentItems(authorDid: String) async throws -> Int {
    let rows = try await pool.query(
      "DELETE FROM content_items WHERE author_did = \(authorDid) RETURNING 1",
      logger: logger
    )
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func fetchContentIdentity(uri: String) async throws -> IndexedContentIdentity? {
    let rows = try await pool.query(
      """
      SELECT uri, cid, author_did, collection
      FROM content_items
      WHERE uri = \(uri)
        AND expires_at > NOW()
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (storedUri, cid, authorDid, collection) = try row.decode(
        (String, String, String, String).self
      )
      return IndexedContentIdentity(
        uri: storedUri,
        cid: cid,
        authorDid: authorDid,
        collection: collection
      )
    }
    return nil
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

  public func listContentItemsForPublicationSite(
    authorDid: String,
    publicationSite: String,
    limit: Int
  ) async throws -> [(uri: String, renderJSON: String)] {
    let capped = max(1, min(limit, 2_000))
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.uri, ci.render_json::text
      FROM content_items ci
      WHERE ci.author_did = \(authorDid)
        AND ci.publication_site = \(publicationSite)
        AND ci.expires_at > \(now)
      ORDER BY ci.created_at DESC, ci.uri DESC
      LIMIT \(capped)
      """,
      logger: logger
    )
    var items: [(uri: String, renderJSON: String)] = []
    for try await row in rows {
      let (uri, renderJSON): (String, String) = try row.decode((String, String).self)
      items.append((uri, renderJSON))
    }
    return items
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
    limit: Int,
    readFloorAt: Date?
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

    let siteKeys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    if scoped, !siteKeys.isEmpty {
      let fetched = try await fetchSiteScopedContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        siteKeys: siteKeys,
        filter: filter,
        cursor: dbCursor,
        limit: pageLimit + 1,
        now: now,
        readFloorAt: readFloorAt
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
        dbHasMore: fetched.count > pageLimit
      )
    }

    if !scoped {
      let fetched = try await fetchContentBatch(
        viewerDid: viewerDid,
        authorDid: authorDid,
        filter: filter,
        cursor: dbCursor,
        limit: batchSize,
        now: now,
        readFloorAt: readFloorAt
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
        now: now,
        readFloorAt: readFloorAt
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

  private func fetchSiteScopedContentBatch(
    viewerDid: String,
    authorDid: String,
    siteKeys: [String],
    filter: EntryListFilter,
    cursor: (createdAt: Date, uri: String)?,
    limit: Int,
    now: Date,
    readFloorAt: Date?
  ) async throws -> [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] {
    let rows: PostgresRowSequence
    let unreadFloor = readFloorAt ?? Date(timeIntervalSince1970: 0)
    switch (filter, cursor) {
    case (.all, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND ci.publication_site = ANY(\(siteKeys))
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
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND rm.subject_uri IS NULL
          AND ci.created_at > \(unreadFloor)
          AND ci.publication_site = ANY(\(siteKeys))
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
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND ci.publication_site = ANY(\(siteKeys))
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
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND ci.publication_site = ANY(\(siteKeys))
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
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND rm.subject_uri IS NULL
          AND ci.created_at > \(unreadFloor)
          AND ci.publication_site = ANY(\(siteKeys))
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
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND ci.publication_site = ANY(\(siteKeys))
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

  private func fetchContentBatch(
    viewerDid: String,
    authorDid: String,
    filter: EntryListFilter,
    cursor: (createdAt: Date, uri: String)?,
    limit: Int,
    now: Date,
    readFloorAt: Date?
  ) async throws -> [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] {
    let rows: PostgresRowSequence
    let unreadFloor = readFloorAt ?? Date(timeIntervalSince1970: 0)
    switch (filter, cursor) {
    case (.all, nil):
      rows = try await pool.query(
        """
        SELECT ci.uri, ci.render_json::text, ci.created_at, ci.publication_site
        FROM content_items ci
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
          AND ci.created_at > \(unreadFloor)
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
          AND ci.created_at > \(unreadFloor)
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

    let siteKeys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    if !siteKeys.isEmpty {
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::int
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(authorDid)
          AND ci.expires_at > \(now)
          AND rm.subject_uri IS NULL
          AND ci.publication_site = ANY(\(siteKeys))
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

  public func countUnreadEntriesBatch(
    viewerDid: String,
    scopes: [PublicationUnreadScope]
  ) async throws -> [String: Int] {
    guard !scopes.isEmpty else { return [:] }

    let authorDids = Array(Set(scopes.map(\.authorDid)))
    let now = Date()
    let rows = try await pool.query(
      """
      SELECT ci.author_did, ci.publication_site, COUNT(*)::int
      FROM content_items ci
      LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
      WHERE ci.author_did = ANY(\(authorDids))
        AND ci.expires_at > \(now)
        AND rm.subject_uri IS NULL
      GROUP BY ci.author_did, ci.publication_site
      """,
      logger: logger
    )

    var unreadSiteCountsByAuthor: [String: [UnreadSiteCount]] = Dictionary(
      uniqueKeysWithValues: authorDids.map { ($0, []) }
    )
    for try await row in rows {
      let (authorDid, site, count): (String, String?, Int) = try row.decode((String, String?, Int).self)
      unreadSiteCountsByAuthor[authorDid, default: []].append(
        UnreadSiteCount(site: site, count: count)
      )
    }

    return ThinAppViewQuerySupport.batchUnreadCounts(
      scopes: scopes,
      unreadSiteCountsByAuthor: unreadSiteCountsByAuthor
    )
  }

  public func upsertPublicationScopes(_ scopes: [AppViewPublicationScope]) async throws {
    guard !scopes.isEmpty else { return }
    for scope in scopes {
      let publicationScopeAtUrisJSON = try Self.jsonString(scope.publicationScopeAtUris)
      let publicationSiteUrlsJSON = try Self.jsonString(scope.publicationSiteUrls)
      let scopeKeysJSON = try Self.jsonString(scope.scopeKeys)
      let sectionKeysJSON = try Self.jsonString(scope.sectionKeys)
      try await pool.query(
        """
        INSERT INTO appview_publication_scopes
          (viewer_did, publication_id, author_did, publication_at_uri,
           publication_scope_at_uris, publication_site_urls, scope_keys,
           section_keys, updated_at)
        VALUES
          (\(scope.viewerDid), \(scope.publicationId), \(scope.authorDid), \(scope.publicationAtUri),
           \(publicationScopeAtUrisJSON)::jsonb, \(publicationSiteUrlsJSON)::jsonb,
           \(scopeKeysJSON)::jsonb, \(sectionKeysJSON)::jsonb, \(scope.updatedAt))
        ON CONFLICT (viewer_did, publication_id)
        DO UPDATE SET
          author_did = EXCLUDED.author_did,
          publication_at_uri = EXCLUDED.publication_at_uri,
          publication_scope_at_uris = EXCLUDED.publication_scope_at_uris,
          publication_site_urls = EXCLUDED.publication_site_urls,
          scope_keys = EXCLUDED.scope_keys,
          section_keys = EXCLUDED.section_keys,
          updated_at = EXCLUDED.updated_at
        """,
        logger: logger
      )
    }
  }

  public func replacePublicationScopes(
    viewerDid: String,
    scopes: [AppViewPublicationScope]
  ) async throws {
    try await pool.query(
      "DELETE FROM appview_publication_scopes WHERE viewer_did = \(viewerDid)",
      logger: logger
    )
    try await upsertPublicationScopes(scopes)
  }

  public func fetchUnreadCounters(
    viewerDid: String,
    publicationIds: [String]?
  ) async throws -> [AppViewUnreadCounter] {
    let rows: PostgresRowSequence
    if let publicationIds, !publicationIds.isEmpty {
      rows = try await pool.query(
        """
        SELECT publication_id, unread_count, generation, accuracy, dirty, counted_at
        FROM appview_unread_counters
        WHERE viewer_did = \(viewerDid)
          AND publication_id = ANY(\(publicationIds))
        """,
        logger: logger
      )
    } else {
      rows = try await pool.query(
        """
        SELECT publication_id, unread_count, generation, accuracy, dirty, counted_at
        FROM appview_unread_counters
        WHERE viewer_did = \(viewerDid)
        """,
        logger: logger
      )
    }
    var counters: [AppViewUnreadCounter] = []
    for try await row in rows {
      if let counter = try Self.unreadCounter(from: row) {
        counters.append(counter)
      }
    }
    return counters
  }

  public func refreshUnreadCounters(
    viewerDid: String,
    scopes: [PublicationUnreadScope]
  ) async throws -> [AppViewUnreadCounter] {
    guard !scopes.isEmpty else { return [] }
    let exactCounts = try await countUnreadEntriesBatch(viewerDid: viewerDid, scopes: scopes)
    let floors = try await readFloors(viewerDid: viewerDid, publicationIds: scopes.map(\.publicationId))
    let countedAt = Date()
    let generation = AppViewUnreadCounterSupport.generation(for: countedAt)
    var counters: [AppViewUnreadCounter] = []

    for scope in scopes {
      let count: Int
      if let floor = floors[scope.publicationId] {
        count = try await countUnreadEntriesAfterFloor(
          viewerDid: viewerDid,
          scope: scope,
          readFloorAt: floor
        )
      } else {
        count = exactCounts[scope.publicationId] ?? 0
      }
      let counter = AppViewUnreadCounter(
        publicationId: scope.publicationId,
        unreadCount: count,
        generation: generation,
        accuracy: .exact,
        dirty: false,
        countedAt: countedAt
      )
      try await upsertUnreadCounter(counter, viewerDid: viewerDid)
      counters.append(counter)
    }
    return counters
  }

  public func incrementUnreadCountersForContentItem(_ item: IndexedContentItem) async throws {
    let scopes = try await publicationScopes(authorDid: item.authorDid, viewerDid: nil)
      .filter {
        AppViewUnreadCounterSupport.contentMatchesScope(
          authorDid: item.authorDid,
          publicationSite: item.publicationSite,
          scope: $0
        )
      }
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Date()
    for scope in scopes {
      if let floor = try await readFloor(viewerDid: scope.viewerDid, publicationId: scope.publicationId),
         item.createdAt <= floor
      {
        continue
      }
      let alreadyRead = try await hasReadMark(viewerDid: scope.viewerDid, subjectUri: item.uri)
      guard !alreadyRead else { continue }
      try await adjustUnreadCounter(
        viewerDid: scope.viewerDid,
        publicationId: scope.publicationId,
        delta: 1,
        generation: generation,
        countedAt: countedAt
      )
    }
  }

  public func markUnreadCountersDirtyForContent(authorDid: String, publicationSite: String?) async throws {
    let scopes = try await publicationScopes(authorDid: authorDid, viewerDid: nil)
      .filter {
        AppViewUnreadCounterSupport.contentMatchesScope(
          authorDid: authorDid,
          publicationSite: publicationSite,
          scope: $0
        )
      }
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Date()
    for scope in scopes {
      try await markUnreadCounterDirty(
        viewerDid: scope.viewerDid,
        publicationId: scope.publicationId,
        generation: generation,
        countedAt: countedAt
      )
    }
  }

  public func adjustUnreadCountersForReadState(
    viewerDid: String,
    subjectUri: String,
    delta: Int
  ) async throws {
    guard delta != 0 else { return }
    guard let content = try await contentCounterFields(uri: subjectUri) else { return }
    let scopes = try await publicationScopes(authorDid: content.authorDid, viewerDid: viewerDid)
      .filter {
        AppViewUnreadCounterSupport.contentMatchesScope(
          authorDid: content.authorDid,
          publicationSite: content.publicationSite,
          scope: $0
        )
      }
    guard !scopes.isEmpty else { return }
    let generation = AppViewUnreadCounterSupport.generation()
    let countedAt = Date()
    for scope in scopes {
      if let floor = try await readFloor(viewerDid: viewerDid, publicationId: scope.publicationId),
         content.createdAt <= floor
      {
        continue
      }
      try await adjustUnreadCounter(
        viewerDid: viewerDid,
        publicationId: scope.publicationId,
        delta: delta,
        generation: generation,
        countedAt: countedAt
      )
    }
  }

  public func markAllReadCounters(
    viewerDid: String,
    publicationIds: [String],
    readAt: Date
  ) async throws -> [AppViewUnreadCounter] {
    let uniqueIds = Array(Set(publicationIds)).sorted()
    guard !uniqueIds.isEmpty else { return [] }
    let generation = AppViewUnreadCounterSupport.generation(for: readAt)
    var counters: [AppViewUnreadCounter] = []
    for publicationId in uniqueIds {
      try await pool.query(
        """
        INSERT INTO appview_publication_read_floors
          (viewer_did, publication_id, read_floor_at, generation, updated_at)
        VALUES
          (\(viewerDid), \(publicationId), \(readAt), \(generation), \(readAt))
        ON CONFLICT (viewer_did, publication_id)
        DO UPDATE SET
          read_floor_at = EXCLUDED.read_floor_at,
          generation = EXCLUDED.generation,
          updated_at = EXCLUDED.updated_at
        """,
        logger: logger
      )
      let counter = AppViewUnreadCounter(
        publicationId: publicationId,
        unreadCount: 0,
        generation: generation,
        accuracy: .estimated,
        dirty: true,
        countedAt: readAt
      )
      try await upsertUnreadCounter(counter, viewerDid: viewerDid)
      counters.append(counter)
    }
    return counters
  }

  public func deleteExpiredContent(before: Date, batchSize: Int) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM content_items
        WHERE expires_at <= \(before)
        ORDER BY expires_at, uri
        LIMIT \(batchSize)
      )
      DELETE FROM content_items AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING target.uri
      """,
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }

  public func deleteExpiredReadMarks(before: Date, batchSize: Int) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM read_marks
        WHERE created_at <= \(before)
        ORDER BY created_at, viewer_did, subject_uri
        LIMIT \(batchSize)
      )
      DELETE FROM read_marks AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING target.subject_uri
      """,
      logger: logger
    )
    var count = 0
    for try await _ in rows { count += 1 }
    return count
  }

  public func deleteExpiredTapEventReceipts(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM appview_tap_event_receipts
        WHERE environment = \(environment) AND expires_at <= \(before)
        ORDER BY expires_at, event_id
        LIMIT \(batchSize)
      )
      DELETE FROM appview_tap_event_receipts AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING 1
      """,
      logger: logger
    )
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func deleteExpiredProjectionRepairs(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    let rows = try await pool.query(
      """
      WITH doomed AS (
        SELECT ctid FROM appview_projection_repair_outbox
        WHERE environment = \(environment) AND status = 'failed' AND expires_at <= \(before)
        ORDER BY expires_at, id
        LIMIT \(batchSize)
      )
      DELETE FROM appview_projection_repair_outbox AS target USING doomed
      WHERE target.ctid = doomed.ctid
      RETURNING 1
      """,
      logger: logger
    )
    var deleted = 0
    for try await _ in rows { deleted += 1 }
    return deleted
  }

  public func desiredTapRepositoryScope(limit: Int) async throws -> TapDesiredRepositoryScope {
    let limit = max(1, min(limit, 10_000))
    let scanBatchSize = 500
    var repoDids: [String] = []
    var after = ""
    while repoDids.count <= limit {
      let rows = try await pool.query(
        """
        SELECT DISTINCT author_did
        FROM appview_publication_scopes
        WHERE author_did > \(after)
        ORDER BY author_did
        LIMIT \(scanBatchSize)
        """,
        logger: logger
      )
      var page: [String] = []
      for try await row in rows {
        page.append(try row.decode(String.self))
      }
      guard let last = page.last else { break }
      repoDids.append(contentsOf: page.filter(ATProtoRepositoryDIDValidator.isValid))
      after = last
      if page.count < scanBatchSize { break }
    }
    return TapDesiredRepositoryScope(
      repoDids: Array(repoDids.prefix(limit)),
      truncated: repoDids.count > limit
    )
  }

  public func registeredTapRepositoryDids(environment: String) async throws -> [String] {
    let rows = try await pool.query(
      """
      SELECT repo_did
      FROM appview_tap_repository_registrations
      WHERE environment = \(environment) AND is_registered = TRUE
      ORDER BY repo_did
      """,
      logger: logger
    )
    var repoDids: [String] = []
    for try await row in rows {
      repoDids.append(try row.decode(String.self))
    }
    return repoDids
  }

  public func markTapRepositoriesRegistered(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws {
    guard !repoDids.isEmpty else { return }
    try await pool.withTransaction(logger: logger) { connection in
      for repoDid in repoDids {
        try await connection.query(
          """
          INSERT INTO appview_tap_repository_registrations
            (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
          VALUES (\(environment), \(repoDid), TRUE, \(at), NULL, \(at))
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            is_registered = TRUE,
            registered_at = EXCLUDED.registered_at,
            removed_at = NULL,
            updated_at = EXCLUDED.updated_at
          """,
          logger: logger
        )
      }
    }
  }

  public func markTapRepositoriesRemoved(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws {
    guard !repoDids.isEmpty else { return }
    try await pool.withTransaction(logger: logger) { connection in
      for repoDid in repoDids {
        try await connection.query(
          """
          INSERT INTO appview_tap_repository_registrations
            (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
          VALUES (\(environment), \(repoDid), FALSE, NULL, \(at), \(at))
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            is_registered = FALSE,
            removed_at = EXCLUDED.removed_at,
            updated_at = EXCLUDED.updated_at
          """,
          logger: logger
        )
      }
    }
  }

  public func recordIngestionCheckpoint(
    environment: String,
    source: String,
    repoDid: String,
    collection: String,
    cursor: String?,
    eventTime: Date?,
    observedAt: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_checkpoints
        (environment, source, repo_did, collection, cursor, event_time, observed_at)
      VALUES
        (\(environment), \(source), \(repoDid), \(collection), \(cursor), \(eventTime), \(observedAt))
      ON CONFLICT (environment, source, repo_did, collection)
      DO UPDATE SET
        cursor = EXCLUDED.cursor,
        event_time = EXCLUDED.event_time,
        observed_at = EXCLUDED.observed_at
      """,
      logger: logger
    )
  }

  public func fetchTapRepositorySyncState(
    environment: String,
    repoDid: String
  ) async throws -> TapRepositorySyncState? {
    let rows = try await pool.query(
      """
      SELECT repo_rev, account_status, pds_base, last_event_id, last_event_live,
             parity_status, matched_event_count, mismatched_event_count,
             last_mismatch, last_indexed_at, last_validated_at, updated_at
      FROM appview_tap_repo_state
      WHERE environment = \(environment)
        AND repo_did = \(repoDid)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let decoded = try row.decode(
        (
          String?, String, String?, Int64?, Bool, String, Int64, Int64,
          String?, Date?, Date?, Date
        ).self
      )
      guard
        let accountStatus = TapAccountStatus(rawValue: decoded.1),
        let parityStatus = TapParityStatus(rawValue: decoded.5)
      else { return nil }
      return TapRepositorySyncState(
        environment: environment,
        repoDid: repoDid,
        repoRev: decoded.0,
        accountStatus: accountStatus,
        pdsBase: decoded.2,
        lastEventId: decoded.3,
        lastEventLive: decoded.4,
        parityStatus: parityStatus,
        matchedEventCount: decoded.6,
        mismatchedEventCount: decoded.7,
        lastMismatch: decoded.8,
        lastIndexedAt: decoded.9,
        lastValidatedAt: decoded.10,
        updatedAt: decoded.11
      )
    }
    return nil
  }

  public func upsertTapRepositorySyncState(_ state: TapRepositorySyncState) async throws {
    try await pool.query(
      """
      INSERT INTO appview_tap_repo_state
        (environment, repo_did, repo_rev, account_status, pds_base,
         last_event_id, last_event_live, parity_status, matched_event_count,
         mismatched_event_count, last_mismatch, last_indexed_at,
         last_validated_at, updated_at)
      VALUES
        (\(state.environment), \(state.repoDid), \(state.repoRev),
         \(state.accountStatus.rawValue), \(state.pdsBase), \(state.lastEventId),
         \(state.lastEventLive), \(state.parityStatus.rawValue),
         \(state.matchedEventCount), \(state.mismatchedEventCount),
         \(state.lastMismatch), \(state.lastIndexedAt), \(state.lastValidatedAt),
         \(state.updatedAt))
      ON CONFLICT (environment, repo_did)
      DO UPDATE SET
        repo_rev = EXCLUDED.repo_rev,
        account_status = EXCLUDED.account_status,
        pds_base = EXCLUDED.pds_base,
        last_event_id = EXCLUDED.last_event_id,
        last_event_live = EXCLUDED.last_event_live,
        parity_status = EXCLUDED.parity_status,
        matched_event_count = EXCLUDED.matched_event_count,
        mismatched_event_count = EXCLUDED.mismatched_event_count,
        last_mismatch = EXCLUDED.last_mismatch,
        last_indexed_at = EXCLUDED.last_indexed_at,
        last_validated_at = EXCLUDED.last_validated_at,
        updated_at = EXCLUDED.updated_at
      """,
      logger: logger
    )
  }

  public func hasProcessedTapEvent(environment: String, eventId: Int64) async throws -> Bool {
    let rows = try await pool.query(
      """
      SELECT EXISTS(
        SELECT 1 FROM appview_tap_event_receipts
        WHERE environment = \(environment) AND event_id = \(eventId)
      )
      """,
      logger: logger
    )
    for try await row in rows { return try row.decode(Bool.self) }
    return false
  }

  public func commitTapEvent(
    state: TapRepositorySyncState,
    eventId: Int64,
    eventType: String,
    parityEvidence: TapParityEventEvidence?,
    processedAt: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO appview_tap_repo_state
          (environment, repo_did, repo_rev, account_status, pds_base,
           last_event_id, last_event_live, parity_status, matched_event_count,
           mismatched_event_count, last_mismatch, last_indexed_at,
           last_validated_at, updated_at)
        VALUES
          (\(state.environment), \(state.repoDid), \(state.repoRev),
           \(state.accountStatus.rawValue), \(state.pdsBase), \(state.lastEventId),
           \(state.lastEventLive), \(state.parityStatus.rawValue),
           \(state.matchedEventCount), \(state.mismatchedEventCount),
           \(state.lastMismatch), \(state.lastIndexedAt), \(state.lastValidatedAt),
           \(state.updatedAt))
        ON CONFLICT (environment, repo_did)
        DO UPDATE SET
          repo_rev = EXCLUDED.repo_rev,
          account_status = EXCLUDED.account_status,
          pds_base = EXCLUDED.pds_base,
          last_event_id = EXCLUDED.last_event_id,
          last_event_live = EXCLUDED.last_event_live,
          parity_status = EXCLUDED.parity_status,
          matched_event_count = EXCLUDED.matched_event_count,
          mismatched_event_count = EXCLUDED.mismatched_event_count,
          last_mismatch = EXCLUDED.last_mismatch,
          last_indexed_at = EXCLUDED.last_indexed_at,
          last_validated_at = EXCLUDED.last_validated_at,
          updated_at = EXCLUDED.updated_at
        """,
        logger: logger
      )
      let expiresAt = processedAt.addingTimeInterval(30 * 86_400)
      try await connection.query(
        """
        INSERT INTO appview_tap_event_receipts
          (environment, event_id, repo_did, event_type, processed_at, expires_at)
        VALUES
          (\(state.environment), \(eventId), \(state.repoDid), \(eventType),
           \(processedAt), \(expiresAt))
        ON CONFLICT (environment, event_id) DO NOTHING
        """,
        logger: logger
      )
      if let parityEvidence {
        if let mismatchKind = parityEvidence.mismatchKind {
          try await connection.query(
            """
            INSERT INTO appview_tap_parity_discrepancies
              (environment, event_id, repo_did, uri, collection, mismatch_kind,
               expected_cid, observed_cid, status, opened_at)
            VALUES
              (\(state.environment), \(eventId), \(state.repoDid), \(parityEvidence.uri),
               \(parityEvidence.collection), \(mismatchKind), \(parityEvidence.expectedCid),
               \(parityEvidence.observedCid), 'open', \(processedAt))
            ON CONFLICT (environment, event_id) DO NOTHING
            """,
            logger: logger
          )
        } else {
          try await connection.query(
            """
            UPDATE appview_tap_parity_discrepancies
            SET status = 'resolved', resolved_at = \(processedAt), resolution_event_id = \(eventId)
            WHERE environment = \(state.environment) AND repo_did = \(state.repoDid)
              AND uri = \(parityEvidence.uri) AND status = 'open'
            """,
            logger: logger
          )
        }
        let countRows = try await connection.query(
          """
          SELECT COUNT(*)::bigint FROM appview_tap_parity_discrepancies
          WHERE environment = \(state.environment) AND repo_did = \(state.repoDid)
            AND status = 'open'
          """,
          logger: logger
        )
        var openCount: Int64 = 0
        for try await row in countRows { openCount = try row.decode(Int64.self) }
        let aggregateStatus = openCount == 0 ? TapParityStatus.matched : .mismatch
        try await connection.query(
          """
          UPDATE appview_tap_repo_state
          SET parity_status = \(aggregateStatus.rawValue),
              last_mismatch = CASE WHEN \(openCount) = 0 THEN NULL ELSE last_mismatch END
          WHERE environment = \(state.environment) AND repo_did = \(state.repoDid)
          """,
          logger: logger
        )
      }
    }
  }

  public func listTapParityDiscrepancies(
    environment: String,
    repoDid: String
  ) async throws -> [TapParityDiscrepancy] {
    let rows = try await pool.query(
      """
      SELECT event_id, uri, collection, mismatch_kind, expected_cid, observed_cid,
             status, opened_at, resolved_at, resolution_event_id
      FROM appview_tap_parity_discrepancies
      WHERE environment = \(environment) AND repo_did = \(repoDid)
      ORDER BY event_id
      """,
      logger: logger
    )
    var discrepancies: [TapParityDiscrepancy] = []
    for try await row in rows {
      let value = try row.decode(
        (Int64, String, String, String, String?, String?, String, Date, Date?, Int64?).self
      )
      guard let status = TapParityDiscrepancyStatus(rawValue: value.6) else { continue }
      discrepancies.append(
        TapParityDiscrepancy(
          environment: environment,
          eventId: value.0,
          repoDid: repoDid,
          uri: value.1,
          collection: value.2,
          mismatchKind: value.3,
          expectedCid: value.4,
          observedCid: value.5,
          status: status,
          openedAt: value.7,
          resolvedAt: value.8,
          resolutionEventId: value.9
        )
      )
    }
    return discrepancies
  }

  public func applyTapContentMutation(
    _ mutation: TapContentMutation,
    environment: String,
    eventId: Int64,
    repoRev: String,
    eventTime: Date,
    observedAt: Date
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let publicationSite: String?
      let action: String
      switch mutation {
      case .upsert(let item):
        publicationSite = item.publicationSite
        action = "upsert"
        let renderJSON = try item.render.encodedJSON()
        try await connection.query(
          """
          INSERT INTO content_items
            (uri, cid, author_did, collection, created_at, indexed_at,
             publication_site, render_json, expires_at)
          VALUES
            (\(item.uri), \(item.cid), \(item.authorDid), \(item.collection),
             \(item.createdAt), \(item.indexedAt), \(item.publicationSite),
             \(renderJSON)::jsonb, \(item.expiresAt))
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
      case .delete(let uri, _, _):
        var existingSite: String?
        let rows = try await connection.query(
          "SELECT publication_site FROM content_items WHERE uri = \(uri) LIMIT 1",
          logger: logger
        )
        for try await row in rows {
          existingSite = try row.decode(String?.self)
        }
        publicationSite = existingSite
        action = "delete"
        try await connection.query(
          "DELETE FROM content_items WHERE uri = \(uri)",
          logger: logger
        )
      }

      try await connection.query(
        """
        INSERT INTO appview_ingestion_checkpoints
          (environment, source, repo_did, collection, cursor, event_time, observed_at)
        VALUES
          (\(environment), 'tap', \(mutation.authorDid), \(mutation.collection), \(String(eventId)),
           \(eventTime), \(observedAt))
        ON CONFLICT (environment, source, repo_did, collection) DO UPDATE SET
          cursor = EXCLUDED.cursor,
          event_time = EXCLUDED.event_time,
          observed_at = EXCLUDED.observed_at
        """,
        logger: logger
      )

      let repairId = "\(environment):\(eventId)"
      let expiresAt = observedAt.addingTimeInterval(30 * 86_400)
      try await connection.query(
        """
        INSERT INTO appview_projection_repair_outbox
          (id, environment, event_id, uri, author_did, publication_site, action,
           status, attempts, next_attempt_at, created_at, updated_at, expires_at)
        VALUES
          (\(repairId), \(environment), \(eventId), \(mutation.uri),
           \(mutation.authorDid), \(publicationSite), \(action), 'queued', 0,
           \(observedAt), \(observedAt), \(observedAt), \(expiresAt))
        ON CONFLICT (environment, event_id) DO NOTHING
        """,
        logger: logger
      )
      _ = repoRev
    }
  }

  public func projectionRepairBacklog(
    environment: String,
    at: Date
  ) async throws -> AppViewProjectionRepairBacklogSnapshot {
    let rows = try await pool.query(
      """
      SELECT
        COUNT(*) FILTER (WHERE status = 'queued')::bigint,
        COUNT(*) FILTER (WHERE status = 'running')::bigint,
        COUNT(*) FILTER (WHERE status = 'failed')::bigint,
        MIN(created_at) FILTER (WHERE status IN ('queued', 'running', 'failed'))
      FROM appview_projection_repair_outbox
      WHERE environment = \(environment)
      """,
      logger: logger
    )
    for try await row in rows {
      let decoded = try row.decode((Int64, Int64, Int64, Date?).self)
      guard let queuedCount = Int(exactly: decoded.0),
        let runningCount = Int(exactly: decoded.1),
        let failedCount = Int(exactly: decoded.2)
      else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      let hasActionableRepairs = queuedCount > 0 || runningCount > 0 || failedCount > 0
      guard queuedCount >= 0, runningCount >= 0, failedCount >= 0 else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      if hasActionableRepairs {
        guard let oldestActionableAt = decoded.3, oldestActionableAt <= at else {
          throw AppViewProjectionRepairError.invalidBacklogEvidence
        }
      } else if decoded.3 != nil {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      return AppViewProjectionRepairBacklogSnapshot(
        environment: environment,
        queuedCount: queuedCount,
        runningCount: runningCount,
        failedCount: failedCount,
        oldestActionableAt: decoded.3,
        oldestActionableAgeSeconds: decoded.3.map { at.timeIntervalSince($0) },
        observedAt: at
      )
    }
    throw AppViewProjectionRepairError.invalidBacklogEvidence
  }

  public func claimProjectionRepair(
    environment: String,
    workerId: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> AppViewProjectionRepair? {
    let rows = try await pool.query(
      """
      WITH candidate AS (
        SELECT id
        FROM appview_projection_repair_outbox
        WHERE environment = \(environment)
          AND ((status = 'queued' AND next_attempt_at <= \(at))
            OR (status = 'running' AND lease_until <= \(at)))
        ORDER BY created_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1
      )
      UPDATE appview_projection_repair_outbox AS repair
      SET status = 'running', lease_owner = \(workerId), lease_until = \(leaseUntil),
          updated_at = \(at)
      FROM candidate
      WHERE repair.environment = \(environment) AND repair.id = candidate.id
      RETURNING repair.id, repair.environment, repair.event_id, repair.uri,
                repair.author_did, repair.publication_site, repair.action, repair.attempts
      """,
      logger: logger
    )
    for try await row in rows {
      let decoded = try row.decode(
        (String, String, Int64, String, String, String?, String, Int).self
      )
      return AppViewProjectionRepair(
        id: decoded.0,
        environment: decoded.1,
        eventId: decoded.2,
        uri: decoded.3,
        authorDid: decoded.4,
        publicationSite: decoded.5,
        action: decoded.6,
        attempts: decoded.7,
        leaseOwner: workerId,
        leaseUntil: leaseUntil
      )
    }
    return nil
  }

  public func completeProjectionRepair(
    environment: String,
    id: String,
    workerId: String
  ) async throws {
    let rows = try await pool.query(
      """
      DELETE FROM appview_projection_repair_outbox
      WHERE environment = \(environment) AND id = \(id)
        AND status = 'running' AND lease_owner = \(workerId)
      RETURNING 1
      """,
      logger: logger
    )
    var deleted = false
    for try await _ in rows { deleted = true }
    guard deleted else { throw AppViewProjectionRepairError.staleLease }
  }

  public func failProjectionRepair(
    environment: String,
    id: String,
    workerId: String,
    errorCategory: String,
    retryAt: Date,
    at: Date
  ) async throws {
    let rows = try await pool.query(
      """
      UPDATE appview_projection_repair_outbox
      SET attempts = attempts + 1,
          status = CASE WHEN attempts + 1 >= 5 THEN 'failed' ELSE 'queued' END,
          lease_owner = NULL,
          lease_until = NULL,
          next_attempt_at = \(retryAt),
          last_error = \(errorCategory),
          updated_at = \(at)
      WHERE environment = \(environment) AND id = \(id)
        AND status = 'running' AND lease_owner = \(workerId)
      RETURNING 1
      """,
      logger: logger
    )
    var updated = false
    for try await _ in rows { updated = true }
    guard updated else { throw AppViewProjectionRepairError.staleLease }
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

  public func fetchRssFeedMetadata(normalizedFeedUrl: String) async throws -> RssFeedFetchMetadata? {
    let rows = try await pool.query(
      """
      SELECT etag, last_modified, last_poll_at, backoff_until, consecutive_error_count
      FROM rss_feed_fetch_metadata
      WHERE feed_url = \(normalizedFeedUrl)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (etag, lastModified, lastPollAt, backoffUntil, consecutiveErrorCount) = try row.decode(
        (String?, String?, Date?, Date?, Int).self
      )
      return RssFeedFetchMetadata(
        normalizedFeedUrl: normalizedFeedUrl,
        etag: etag,
        lastModified: lastModified,
        lastPollAt: lastPollAt,
        backoffUntil: backoffUntil,
        consecutiveErrorCount: consecutiveErrorCount
      )
    }
    return nil
  }

  public func storeRssFeedMetadata(_ metadata: RssFeedFetchMetadata) async throws {
    try await pool.query(
      """
      INSERT INTO rss_feed_fetch_metadata
        (feed_url, etag, last_modified, last_poll_at, backoff_until, consecutive_error_count)
      VALUES
        (\(metadata.normalizedFeedUrl), \(metadata.etag), \(metadata.lastModified), \(metadata.lastPollAt), \(metadata.backoffUntil), \(metadata.consecutiveErrorCount))
      ON CONFLICT (feed_url)
      DO UPDATE SET
        etag = EXCLUDED.etag,
        last_modified = EXCLUDED.last_modified,
        last_poll_at = EXCLUDED.last_poll_at,
        backoff_until = EXCLUDED.backoff_until,
        consecutive_error_count = EXCLUDED.consecutive_error_count
      """,
      logger: logger
    )
  }

  private func publicationScopes(
    authorDid: String,
    viewerDid: String?
  ) async throws -> [AppViewPublicationScope] {
    let rows: PostgresRowSequence
    if let viewerDid {
      rows = try await pool.query(
        """
        SELECT viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris::text, publication_site_urls::text,
               scope_keys::text, section_keys::text, updated_at
        FROM appview_publication_scopes
        WHERE author_did = \(authorDid)
          AND viewer_did = \(viewerDid)
        """,
        logger: logger
      )
    } else {
      rows = try await pool.query(
        """
        SELECT viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris::text, publication_site_urls::text,
               scope_keys::text, section_keys::text, updated_at
        FROM appview_publication_scopes
        WHERE author_did = \(authorDid)
        """,
        logger: logger
      )
    }
    var scopes: [AppViewPublicationScope] = []
    for try await row in rows {
      if let scope = try Self.publicationScope(from: row) {
        scopes.append(scope)
      }
    }
    return scopes
  }

  private func readFloors(
    viewerDid: String,
    publicationIds: [String]
  ) async throws -> [String: Date] {
    let uniqueIds = Array(Set(publicationIds)).sorted()
    guard !uniqueIds.isEmpty else { return [:] }
    let rows = try await pool.query(
      """
      SELECT publication_id, read_floor_at
      FROM appview_publication_read_floors
      WHERE viewer_did = \(viewerDid)
        AND publication_id = ANY(\(uniqueIds))
      """,
      logger: logger
    )
    var floors: [String: Date] = [:]
    for try await row in rows {
      let (publicationId, readFloorAt): (String, Date) = try row.decode((String, Date).self)
      floors[publicationId] = readFloorAt
    }
    return floors
  }

  public func readFloor(viewerDid: String, publicationId: String) async throws -> Date? {
    let rows = try await pool.query(
      """
      SELECT read_floor_at
      FROM appview_publication_read_floors
      WHERE viewer_did = \(viewerDid)
        AND publication_id = \(publicationId)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode(Date.self)
    }
    return nil
  }

  private func countUnreadEntriesAfterFloor(
    viewerDid: String,
    scope: PublicationUnreadScope,
    readFloorAt: Date
  ) async throws -> Int {
    let now = Date()
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: scope.publicationAtUri,
      publicationScopeAtUris: scope.publicationScopeAtUris,
      publicationSiteUrls: scope.publicationSiteUrls
    )
    let siteKeys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
      publicationAtUri: scope.publicationAtUri,
      publicationScopeAtUris: scope.publicationScopeAtUris,
      publicationSiteUrls: scope.publicationSiteUrls
    )
    if scoped, !siteKeys.isEmpty {
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::int
        FROM content_items ci
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewerDid) AND rm.subject_uri = ci.uri
        WHERE ci.author_did = \(scope.authorDid)
          AND ci.expires_at > \(now)
          AND ci.created_at > \(readFloorAt)
          AND ci.publication_site = ANY(\(siteKeys))
          AND rm.subject_uri IS NULL
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
      WHERE ci.author_did = \(scope.authorDid)
        AND ci.expires_at > \(now)
        AND ci.created_at > \(readFloorAt)
        AND rm.subject_uri IS NULL
      """,
      logger: logger
    )
    var siteFields: [String?] = []
    for try await row in rows {
      let site: String? = try row.decode(String?.self)
      siteFields.append(site)
    }
    return scoped
      ? ThinAppViewQuerySupport.countMatchingPublicationSites(
        siteFields: siteFields,
        publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls
      )
      : siteFields.count
  }

  private func contentCounterFields(
    uri: String
  ) async throws -> (authorDid: String, publicationSite: String?, createdAt: Date)? {
    let rows = try await pool.query(
      """
      SELECT author_did, publication_site, created_at
      FROM content_items
      WHERE uri = \(uri)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode((String, String?, Date).self)
    }
    return nil
  }

  private func upsertUnreadCounter(
    _ counter: AppViewUnreadCounter,
    viewerDid: String
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_unread_counters
        (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
      VALUES
        (\(viewerDid), \(counter.publicationId), \(counter.unreadCount), \(counter.generation), \(counter.accuracy.rawValue), \(counter.dirty), \(counter.countedAt))
      ON CONFLICT (viewer_did, publication_id)
      DO UPDATE SET
        unread_count = EXCLUDED.unread_count,
        generation = EXCLUDED.generation,
        accuracy = EXCLUDED.accuracy,
        dirty = EXCLUDED.dirty,
        counted_at = EXCLUDED.counted_at
      """,
      logger: logger
    )
  }

  private func adjustUnreadCounter(
    viewerDid: String,
    publicationId: String,
    delta: Int,
    generation: Int64,
    countedAt: Date
  ) async throws {
    let current = try await fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    ).first?.unreadCount ?? 0
    let counter = AppViewUnreadCounter(
      publicationId: publicationId,
      unreadCount: max(0, current + delta),
      generation: generation,
      accuracy: .estimated,
      dirty: true,
      countedAt: countedAt
    )
    try await upsertUnreadCounter(counter, viewerDid: viewerDid)
  }

  private func markUnreadCounterDirty(
    viewerDid: String,
    publicationId: String,
    generation: Int64,
    countedAt: Date
  ) async throws {
    let current = try await fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    ).first?.unreadCount ?? 0
    let counter = AppViewUnreadCounter(
      publicationId: publicationId,
      unreadCount: current,
      generation: generation,
      accuracy: .estimated,
      dirty: true,
      countedAt: countedAt
    )
    try await upsertUnreadCounter(counter, viewerDid: viewerDid)
  }

  private static func publicationScope(from row: PostgresRow) throws -> AppViewPublicationScope? {
    let (
      viewerDid,
      publicationId,
      authorDid,
      publicationAtUri,
      publicationScopeAtUrisJSON,
      publicationSiteUrlsJSON,
      scopeKeysJSON,
      sectionKeysJSON,
      updatedAt
    ) = try row.decode((String, String, String, String?, String, String, String, String, Date).self)
    return AppViewPublicationScope(
      viewerDid: viewerDid,
      publicationId: publicationId,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: try stringArray(fromJSON: publicationScopeAtUrisJSON),
      publicationSiteUrls: try stringArray(fromJSON: publicationSiteUrlsJSON),
      scopeKeys: try stringArray(fromJSON: scopeKeysJSON),
      sectionKeys: try stringArray(fromJSON: sectionKeysJSON),
      updatedAt: updatedAt
    )
  }

  private static func unreadCounter(from row: PostgresRow) throws -> AppViewUnreadCounter? {
    let (publicationId, unreadCount, generation, accuracyRaw, dirty, countedAt) = try row.decode(
      (String, Int, Int64, String, Bool, Date).self
    )
    guard let accuracy = AppViewUnreadCounterAccuracy(rawValue: accuracyRaw) else { return nil }
    return AppViewUnreadCounter(
      publicationId: publicationId,
      unreadCount: unreadCount,
      generation: generation,
      accuracy: accuracy,
      dirty: dirty,
      countedAt: countedAt
    )
  }

  private static func jsonString(_ values: [String]) throws -> String {
    let data = try JSONEncoder().encode(values)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return string
  }

  private static func stringArray(fromJSON raw: String) throws -> [String] {
    guard let data = raw.data(using: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return try JSONDecoder().decode([String].self, from: data)
  }
}
