@preconcurrency import GRDB
import Foundation
import Logging
import OperationsCore

public actor SQLiteThinAppViewStore: ThinAppViewStore {
  private let db: DatabasePool
  private let logger: Logger

public init(path dbPath: String, logger: Logger) throws {
    self.logger = logger
    var config = Configuration()
    config.label = "com.thesocialwire.thin-appview"
    self.db = try DatabasePool(path: dbPath, configuration: config)
    try db.write { db in
      try Self.migrate(db)
    }
    logger.info("SQLiteThinAppViewStore initialised", metadata: ["path": .string(dbPath)])
  }

  public func ping() async throws {
    _ = try await db.read { database in try Int.fetchOne(database, sql: "SELECT 1") }
  }

  private static func migrate(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS content_items (
        uri TEXT PRIMARY KEY,
        cid TEXT NOT NULL,
        author_did TEXT NOT NULL,
        collection TEXT NOT NULL,
        created_at TEXT NOT NULL,
        indexed_at TEXT NOT NULL,
        publication_site TEXT,
        render_json TEXT NOT NULL,
        expires_at TEXT NOT NULL
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_collection_created
        ON content_items (author_did, collection, created_at DESC);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_expires
        ON content_items (expires_at);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_expires
        ON content_items (author_did, expires_at);
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_content_items_author_site_expires
        ON content_items (author_did, publication_site, expires_at);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS read_marks (
        viewer_did TEXT NOT NULL,
        subject_uri TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, subject_uri)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_read_marks_viewer_created
        ON read_marks (viewer_did, created_at DESC);
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_read_marks_cleanup
        ON read_marks (created_at, viewer_did, subject_uri);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_ingestion_checkpoints (
        environment TEXT NOT NULL,
        source TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        collection TEXT NOT NULL,
        cursor TEXT,
        event_time TEXT,
        observed_at TEXT NOT NULL,
        PRIMARY KEY (environment, source, repo_did, collection)
      );
      """)

    try migrateIngestionCheckpointEnvironmentIfNeeded(db)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_ingestion_checkpoints_observed
        ON appview_ingestion_checkpoints (observed_at);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_repo_state (
        environment TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        repo_rev TEXT,
        account_status TEXT NOT NULL,
        pds_base TEXT,
        last_event_id INTEGER,
        last_event_live INTEGER,
        parity_status TEXT NOT NULL,
        matched_event_count INTEGER NOT NULL DEFAULT 0,
        mismatched_event_count INTEGER NOT NULL DEFAULT 0,
        last_mismatch TEXT,
        last_indexed_at TEXT,
        last_validated_at TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (environment, repo_did)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_repo_state_parity
        ON appview_tap_repo_state (environment, parity_status, updated_at DESC);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_parity_discrepancies (
        environment TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        repo_did TEXT NOT NULL,
        uri TEXT NOT NULL,
        collection TEXT NOT NULL,
        mismatch_kind TEXT NOT NULL,
        expected_cid TEXT,
        observed_cid TEXT,
        status TEXT NOT NULL,
        opened_at TEXT NOT NULL,
        resolved_at TEXT,
        resolution_event_id INTEGER,
        PRIMARY KEY (environment, event_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_parity_discrepancies_open
        ON appview_tap_parity_discrepancies (environment, repo_did, uri, opened_at)
        WHERE status = 'open';
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_event_receipts (
        environment TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        repo_did TEXT NOT NULL,
        event_type TEXT NOT NULL,
        processed_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (environment, event_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_event_receipts_environment_expires
        ON appview_tap_event_receipts (environment, expires_at, event_id);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_tap_repository_registrations (
        environment TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        is_registered INTEGER NOT NULL,
        registered_at TEXT,
        removed_at TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (environment, repo_did)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_tap_repository_registrations_active
        ON appview_tap_repository_registrations (environment, repo_did)
        WHERE is_registered = 1;
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_projection_repair_outbox (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        uri TEXT NOT NULL,
        author_did TEXT NOT NULL,
        publication_site TEXT,
        action TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        lease_owner TEXT,
        lease_until TEXT,
        next_attempt_at TEXT NOT NULL,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (environment, id),
        UNIQUE (environment, event_id)
      );
      """)

    try migrateProjectionRepairEnvironmentPrimaryKeyIfNeeded(db)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_projection_repair_claim
        ON appview_projection_repair_outbox
          (environment, status, next_attempt_at, lease_until, created_at);
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_projection_repair_cleanup
        ON appview_projection_repair_outbox (environment, status, expires_at, id);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS rss_feed_fetch_metadata (
        feed_url TEXT PRIMARY KEY,
        etag TEXT,
        last_modified TEXT,
        last_poll_at TEXT,
        backoff_until TEXT,
        consecutive_error_count INTEGER NOT NULL DEFAULT 0
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_rss_feed_fetch_metadata_backoff
        ON rss_feed_fetch_metadata (backoff_until);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_publication_scopes (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        author_did TEXT NOT NULL,
        publication_at_uri TEXT,
        publication_scope_at_uris TEXT NOT NULL,
        publication_site_urls TEXT NOT NULL,
        scope_keys TEXT NOT NULL,
        section_keys TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_author
        ON appview_publication_scopes (author_did);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_unread_counters (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        unread_count INTEGER NOT NULL,
        generation INTEGER NOT NULL,
        accuracy TEXT NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 0,
        counted_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_appview_unread_counters_dirty
        ON appview_unread_counters (dirty, counted_at);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS appview_publication_read_floors (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        read_floor_at TEXT NOT NULL,
        generation INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)
  }

  /// SQLite cannot add a column to an existing primary key. Rebuild the legacy table while
  /// quarantining its unscoped evidence instead of silently assigning it to the active environment.
  private static func migrateIngestionCheckpointEnvironmentIfNeeded(_ db: Database) throws {
    let columns = try Row.fetchAll(
      db,
      sql: "PRAGMA table_info(appview_ingestion_checkpoints)"
    ).map { row -> String in row["name"] }
    guard !columns.contains("environment") else { return }

    try db.execute(sql: """
      ALTER TABLE appview_ingestion_checkpoints
        RENAME TO appview_ingestion_checkpoints_legacy_unscoped;
      """)
    try db.execute(sql: """
      CREATE TABLE appview_ingestion_checkpoints (
        environment TEXT NOT NULL,
        source TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        collection TEXT NOT NULL,
        cursor TEXT,
        event_time TEXT,
        observed_at TEXT NOT NULL,
        PRIMARY KEY (environment, source, repo_did, collection)
      );
      """)
    try db.execute(sql: """
      INSERT INTO appview_ingestion_checkpoints
        (environment, source, repo_did, collection, cursor, event_time, observed_at)
      SELECT '__legacy_unscoped__', source, repo_did, collection, cursor, event_time, observed_at
      FROM appview_ingestion_checkpoints_legacy_unscoped;
      """)
    try db.execute(sql: "DROP TABLE appview_ingestion_checkpoints_legacy_unscoped;")
  }

  /// Early development builds used a global outbox id primary key. Rebuild it as an
  /// environment-scoped identifier so SQLite has the same isolation contract as Postgres.
  private static func migrateProjectionRepairEnvironmentPrimaryKeyIfNeeded(
    _ db: Database
  ) throws {
    let primaryKeyColumns = try Row.fetchAll(
      db,
      sql: "PRAGMA table_info(appview_projection_repair_outbox)"
    ).compactMap { row -> (position: Int, name: String)? in
      let position: Int = row["pk"]
      guard position > 0 else { return nil }
      return (position, row["name"])
    }.sorted { $0.position < $1.position }.map(\.name)
    guard primaryKeyColumns != ["environment", "id"] else { return }

    try db.execute(sql: """
      ALTER TABLE appview_projection_repair_outbox
        RENAME TO appview_projection_repair_outbox_legacy;
      CREATE TABLE appview_projection_repair_outbox (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        uri TEXT NOT NULL,
        author_did TEXT NOT NULL,
        publication_site TEXT,
        action TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        lease_owner TEXT,
        lease_until TEXT,
        next_attempt_at TEXT NOT NULL,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (environment, id),
        UNIQUE (environment, event_id)
      );
      INSERT INTO appview_projection_repair_outbox (
        environment, id, event_id, uri, author_did, publication_site, action, status,
        attempts, lease_owner, lease_until, next_attempt_at, last_error, created_at,
        updated_at, expires_at
      )
      SELECT environment, id, event_id, uri, author_did, publication_site, action, status,
        attempts, lease_owner, lease_until, next_attempt_at, last_error, created_at,
        updated_at, expires_at
      FROM appview_projection_repair_outbox_legacy;
      DROP TABLE appview_projection_repair_outbox_legacy;
      """)
  }

  public func upsertContentItem(_ item: IndexedContentItem) async throws {
    let renderJSON = try item.render.encodedJSON()
    let createdAt = Self.isoString(from: item.createdAt)
    let indexedAt = Self.isoString(from: item.indexedAt)
    let expiresAt = Self.isoString(from: item.expiresAt)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO content_items
            (uri, cid, author_did, collection, created_at, indexed_at, publication_site, render_json, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (uri) DO UPDATE SET
            cid = excluded.cid,
            author_did = excluded.author_did,
            collection = excluded.collection,
            created_at = excluded.created_at,
            indexed_at = excluded.indexed_at,
            publication_site = excluded.publication_site,
            render_json = excluded.render_json,
            expires_at = excluded.expires_at
          """,
        arguments: [
          item.uri,
          item.cid,
          item.authorDid,
          item.collection,
          createdAt,
          indexedAt,
          item.publicationSite,
          renderJSON,
          expiresAt,
        ]
      )
    }
  }

  public func deleteContentItem(uri: String) async throws {
    try await db.write { db in
      try db.execute(sql: "DELETE FROM content_items WHERE uri = ?", arguments: [uri])
    }
  }

  public func deleteContentItems(authorDid: String) async throws -> Int {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM content_items WHERE author_did = ?",
        arguments: [authorDid]
      )
      return db.changesCount
    }
  }

  public func fetchContentIdentity(uri: String) async throws -> IndexedContentIdentity? {
    let nowIso = Self.isoString(from: Date())
    return try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT uri, cid, author_did, collection
          FROM content_items
          WHERE uri = ?
            AND expires_at > ?
          LIMIT 1
          """,
        arguments: [uri, nowIso]
      ) else { return nil }
      return IndexedContentIdentity(
        uri: row["uri"],
        cid: row["cid"],
        authorDid: row["author_did"],
        collection: row["collection"]
      )
    }
  }

  public func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws {
    let createdAtIso = Self.isoString(from: createdAt)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO read_marks (viewer_did, subject_uri, created_at)
          VALUES (?, ?, ?)
          ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET created_at = excluded.created_at
          """,
        arguments: [viewerDid, subjectUri, createdAtIso]
      )
    }
  }

  public func deleteReadMark(viewerDid: String, subjectUri: String) async throws {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM read_marks WHERE viewer_did = ? AND subject_uri = ?",
        arguments: [viewerDid, subjectUri]
      )
    }
  }

  public func purgeReadMarks(viewerDid: String) async throws {
    try await db.write { db in
      try db.execute(sql: "DELETE FROM read_marks WHERE viewer_did = ?", arguments: [viewerDid])
    }
  }

  public func fetchContentItem(uri: String) async throws -> AppViewEntryListItem? {
    let nowIso = Self.isoString(from: Date())
    let row: (uri: String, renderJSON: String, createdAt: Date)? = try await db.read { db in
      guard
        let fetched = try Row.fetchOne(
          db,
          sql: """
            SELECT ci.uri, ci.render_json, ci.created_at
            FROM content_items ci
            WHERE ci.uri = ? AND ci.expires_at > ?
            LIMIT 1
            """,
          arguments: [uri, nowIso]
        )
      else { return nil }
      return (
        uri: fetched["uri"],
        renderJSON: fetched["render_json"],
        createdAt: Self.date(fromIso: fetched["created_at"]) ?? Date.distantPast
      )
    }
    guard let row else { return nil }
    return ThinAppViewQuerySupport.entryListItems(from: [(row.uri, row.renderJSON, row.createdAt)]).first
  }

  public func fetchContentRender(uri: String) async throws -> ContentRenderFields? {
    let nowIso = Self.isoString(from: Date())
    let renderJSON: String? = try await db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT ci.render_json
          FROM content_items ci
          WHERE ci.uri = ? AND ci.expires_at > ?
          LIMIT 1
          """,
        arguments: [uri, nowIso]
      )
    }
    guard let renderJSON, let data = renderJSON.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ContentRenderFields.self, from: data)
  }

  public func listContentItemsForPublicationSite(
    authorDid: String,
    publicationSite: String,
    limit: Int
  ) async throws -> [(uri: String, renderJSON: String)] {
    let capped = max(1, min(limit, 2_000))
    let nowIso = Self.isoString(from: Date())
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT uri, render_json
          FROM content_items
          WHERE author_did = ?
            AND publication_site = ?
            AND expires_at > ?
          ORDER BY created_at DESC, uri DESC
          LIMIT ?
          """,
        arguments: [authorDid, publicationSite, nowIso, capped]
      )
      return rows.compactMap { row in
        guard
          let uri = row["uri"] as String?,
          let renderJSON = row["render_json"] as String?
        else { return nil }
        return (uri, renderJSON)
      }
    }
  }

  public func hasReadMark(viewerDid: String, subjectUri: String) async throws -> Bool {
    try await db.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT 1
          FROM read_marks
          WHERE viewer_did = ? AND subject_uri = ?
          LIMIT 1
          """,
        arguments: [viewerDid, subjectUri]
      ) != nil
    }
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
    let nowIso = Self.isoString(from: Date())
    let pageLimit = max(1, min(limit, 100))
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
        nowIso: nowIso,
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
        nowIso: nowIso,
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

  private func fetchContentBatch(
    viewerDid: String,
    authorDid: String,
    filter: EntryListFilter,
    cursor: (createdAt: Date, uri: String)?,
    limit: Int,
    nowIso: String,
    readFloorAt: Date?
  ) async throws -> [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] {
    try await db.read { db in
      let joinClause: String
      switch filter {
      case .all:
        joinClause = ""
      case .unread:
        joinClause = """

          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
        """
      case .read:
        joinClause = """

          INNER JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
        """
      }
      var sql = """
        SELECT ci.uri, ci.render_json, ci.created_at, ci.publication_site
        FROM content_items ci
        \(joinClause)
        WHERE ci.author_did = ?
          AND ci.expires_at > ?
        """

      var args: [DatabaseValueConvertible?] = []
      if filter != .all {
        args.append(viewerDid)
      }
      args.append(contentsOf: [authorDid, nowIso])

      switch filter {
      case .all:
        break
      case .unread:
        sql += " AND rm.subject_uri IS NULL"
        if let readFloorAt {
          sql += " AND ci.created_at > ?"
          args.append(Self.isoString(from: readFloorAt))
        }
      case .read:
        break
      }

      if let decoded = cursor {
        sql += " AND (ci.created_at < ? OR (ci.created_at = ? AND ci.uri < ?))"
        let createdIso = Self.isoString(from: decoded.createdAt)
        args.append(contentsOf: [createdIso, createdIso, decoded.uri])
      }

      sql += " ORDER BY ci.created_at DESC, ci.uri DESC LIMIT ?"
      args.append(limit)

      let fetched = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
      return fetched.map { row in
        (
          uri: row["uri"],
          renderJSON: row["render_json"],
          createdAt: Self.date(fromIso: row["created_at"]) ?? Date.distantPast,
          publicationSite: row["publication_site"]
        )
      }
    }
  }

  public func countUnreadEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> Int {
    let nowIso = Self.isoString(from: Date())
    let scoped = ThinAppViewQuerySupport.requiresPublicationSiteFilter(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )

    if !scoped {
      return try await db.read { db in
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*)
            FROM content_items ci
            LEFT JOIN read_marks rm
              ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
            WHERE ci.author_did = ?
              AND ci.expires_at > ?
              AND rm.subject_uri IS NULL
            """,
          arguments: [viewerDid, authorDid, nowIso]
        ) ?? 0
      }
    }

    let siteFields: [String?] = try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ci.publication_site
          FROM content_items ci
          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          WHERE ci.author_did = ?
            AND ci.expires_at > ?
            AND rm.subject_uri IS NULL
          """,
        arguments: [viewerDid, authorDid, nowIso]
      )
      return rows.map { $0["publication_site"] as String? }
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
    let nowIso = Self.isoString(from: Date())
    let placeholders = authorDids.map { _ in "?" }.joined(separator: ", ")

    let unreadSiteCountsByAuthor: [String: [UnreadSiteCount]] = try await db.read { db in
      var grouped: [String: [UnreadSiteCount]] = Dictionary(
        uniqueKeysWithValues: authorDids.map { ($0, []) }
      )
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ci.author_did, ci.publication_site, COUNT(*) AS unread_count
          FROM content_items ci
          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          WHERE ci.author_did IN (\(placeholders))
            AND ci.expires_at > ?
            AND rm.subject_uri IS NULL
          GROUP BY ci.author_did, ci.publication_site
          """,
        arguments: StatementArguments([viewerDid] + authorDids + [nowIso])
      )
      for row in rows {
        let authorDid: String = row["author_did"]
        grouped[authorDid, default: []].append(
          UnreadSiteCount(site: row["publication_site"] as String?, count: row["unread_count"])
        )
      }
      return grouped
    }

    return ThinAppViewQuerySupport.batchUnreadCounts(
      scopes: scopes,
      unreadSiteCountsByAuthor: unreadSiteCountsByAuthor
    )
  }

  public func upsertPublicationScopes(_ scopes: [AppViewPublicationScope]) async throws {
    guard !scopes.isEmpty else { return }
    try await db.write { db in
      for scope in scopes {
        try db.execute(
          sql: """
            INSERT INTO appview_publication_scopes
              (viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris, publication_site_urls, scope_keys,
               section_keys, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
              author_did = excluded.author_did,
              publication_at_uri = excluded.publication_at_uri,
              publication_scope_at_uris = excluded.publication_scope_at_uris,
              publication_site_urls = excluded.publication_site_urls,
              scope_keys = excluded.scope_keys,
              section_keys = excluded.section_keys,
              updated_at = excluded.updated_at
            """,
          arguments: [
            scope.viewerDid,
            scope.publicationId,
            scope.authorDid,
            scope.publicationAtUri,
            try Self.jsonString(scope.publicationScopeAtUris),
            try Self.jsonString(scope.publicationSiteUrls),
            try Self.jsonString(scope.scopeKeys),
            try Self.jsonString(scope.sectionKeys),
            Self.isoString(from: scope.updatedAt),
          ]
        )
      }
    }
  }

  public func replacePublicationScopes(
    viewerDid: String,
    scopes: [AppViewPublicationScope]
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM appview_publication_scopes WHERE viewer_did = ?",
        arguments: [viewerDid]
      )
    }
    try await upsertPublicationScopes(scopes)
  }

  public func fetchUnreadCounters(
    viewerDid: String,
    publicationIds: [String]?
  ) async throws -> [AppViewUnreadCounter] {
    try await db.read { db in
      var sql = """
        SELECT publication_id, unread_count, generation, accuracy, dirty, counted_at
        FROM appview_unread_counters
        WHERE viewer_did = ?
        """
      var args: [DatabaseValueConvertible?] = [viewerDid]
      if let publicationIds, !publicationIds.isEmpty {
        sql += " AND publication_id IN (\(publicationIds.map { _ in "?" }.joined(separator: ", ")))"
        args.append(contentsOf: publicationIds)
      }
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
      return rows.compactMap(Self.unreadCounter(from:))
    }
  }

  public func refreshUnreadCounters(
    viewerDid: String,
    scopes: [PublicationUnreadScope]
  ) async throws -> [AppViewUnreadCounter] {
    guard !scopes.isEmpty else { return [] }
    let exactCounts = try await countUnreadEntriesBatch(viewerDid: viewerDid, scopes: scopes)
    let floors = try await readFloors(viewerDid: viewerDid, publicationIds: scopes.map(\.publicationId))
    let countedAt = Date()
    let countedAtIso = Self.isoString(from: countedAt)
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
      counters.append(
        AppViewUnreadCounter(
          publicationId: scope.publicationId,
          unreadCount: count,
          generation: generation,
          accuracy: .exact,
          dirty: false,
          countedAt: countedAt
        )
      )
    }

    let countersToStore = counters
    try await db.write { db in
      for counter in countersToStore {
        try Self.upsertUnreadCounter(counter, viewerDid: viewerDid, countedAtIso: countedAtIso, db: db)
      }
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
    let countedAt = Self.isoString(from: Date())
    try await db.write { db in
      for scope in scopes {
        if let floor = try Self.readFloor(
          viewerDid: scope.viewerDid,
          publicationId: scope.publicationId,
          db: db
        ),
          item.createdAt <= floor
        {
          continue
        }
        let alreadyRead = try Bool.fetchOne(
          db,
          sql: """
            SELECT 1
            FROM read_marks
            WHERE viewer_did = ? AND subject_uri = ?
            LIMIT 1
            """,
          arguments: [scope.viewerDid, item.uri]
        ) != nil
        guard !alreadyRead else { continue }
        try Self.adjustUnreadCounter(
          viewerDid: scope.viewerDid,
          publicationId: scope.publicationId,
          delta: 1,
          generation: generation,
          countedAtIso: countedAt,
          db: db
        )
      }
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
    let countedAt = Self.isoString(from: Date())
    try await db.write { db in
      for scope in scopes {
        try Self.markUnreadCounterDirty(
          viewerDid: scope.viewerDid,
          publicationId: scope.publicationId,
          generation: generation,
          countedAtIso: countedAt,
          db: db
        )
      }
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
    let countedAt = Self.isoString(from: Date())
    try await db.write { db in
      for scope in scopes {
        if let floor = try Self.readFloor(
          viewerDid: viewerDid,
          publicationId: scope.publicationId,
          db: db
        ),
          content.createdAt <= floor
        {
          continue
        }
        try Self.adjustUnreadCounter(
          viewerDid: viewerDid,
          publicationId: scope.publicationId,
          delta: delta,
          generation: generation,
          countedAtIso: countedAt,
          db: db
        )
      }
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
    let readAtIso = Self.isoString(from: readAt)
    let counters = uniqueIds.map {
      AppViewUnreadCounter(
        publicationId: $0,
        unreadCount: 0,
        generation: generation,
        accuracy: .estimated,
        dirty: true,
        countedAt: readAt
      )
    }
    try await db.write { db in
      for counter in counters {
        try db.execute(
          sql: """
            INSERT INTO appview_publication_read_floors
              (viewer_did, publication_id, read_floor_at, generation, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
              read_floor_at = excluded.read_floor_at,
              generation = excluded.generation,
              updated_at = excluded.updated_at
            """,
          arguments: [viewerDid, counter.publicationId, readAtIso, generation, readAtIso]
        )
        try Self.upsertUnreadCounter(counter, viewerDid: viewerDid, countedAtIso: readAtIso, db: db)
      }
    }
    return counters
  }

  public func readFloor(viewerDid: String, publicationId: String) async throws -> Date? {
    try await db.read { db in
      try Self.readFloor(viewerDid: viewerDid, publicationId: publicationId, db: db)
    }
  }

  public func deleteExpiredContent(before: Date, batchSize: Int) async throws -> Int {
    let beforeIso = Self.isoString(from: before)
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM content_items
          WHERE rowid IN (
            SELECT rowid FROM content_items
            WHERE expires_at <= ?
            ORDER BY expires_at, uri
            LIMIT ?
          )
          """,
        arguments: [beforeIso, batchSize]
      )
      return db.changesCount
    }
  }

  public func deleteExpiredReadMarks(before: Date, batchSize: Int) async throws -> Int {
    let beforeIso = Self.isoString(from: before)
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM read_marks
          WHERE rowid IN (
            SELECT rowid FROM read_marks
            WHERE created_at <= ?
            ORDER BY created_at, viewer_did, subject_uri
            LIMIT ?
          )
          """,
        arguments: [beforeIso, batchSize]
      )
      return db.changesCount
    }
  }

  public func deleteExpiredTapEventReceipts(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM appview_tap_event_receipts
          WHERE rowid IN (
            SELECT rowid FROM appview_tap_event_receipts
            WHERE environment = ? AND expires_at <= ?
            ORDER BY expires_at, event_id
            LIMIT ?
          )
          """,
        arguments: [environment, Self.isoString(from: before), batchSize]
      )
      return db.changesCount
    }
  }

  public func deleteExpiredProjectionRepairs(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM appview_projection_repair_outbox
          WHERE rowid IN (
            SELECT rowid FROM appview_projection_repair_outbox
            WHERE environment = ? AND status = 'failed' AND expires_at <= ?
            ORDER BY expires_at, id
            LIMIT ?
          )
          """,
        arguments: [environment, Self.isoString(from: before), batchSize]
      )
      return db.changesCount
    }
  }

  public func desiredTapRepositoryScope(limit: Int) async throws -> TapDesiredRepositoryScope {
    let limit = max(1, min(limit, 10_000))
    return try await db.read { db in
      let scanBatchSize = 500
      var rows: [String] = []
      var after = ""
      while rows.count <= limit {
        let page = try String.fetchAll(
          db,
          sql: """
            SELECT DISTINCT author_did
            FROM appview_publication_scopes
            WHERE author_did > ?
            ORDER BY author_did
            LIMIT ?
            """,
          arguments: [after, scanBatchSize]
        )
        guard let last = page.last else { break }
        rows.append(contentsOf: page.filter(ATProtoRepositoryDIDValidator.isValid))
        after = last
        if page.count < scanBatchSize { break }
      }
      return TapDesiredRepositoryScope(
        repoDids: Array(rows.prefix(limit)),
        truncated: rows.count > limit
      )
    }
  }

  public func registeredTapRepositoryDids(environment: String) async throws -> [String] {
    try await db.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT repo_did
          FROM appview_tap_repository_registrations
          WHERE environment = ? AND is_registered = 1
          ORDER BY repo_did
          """,
        arguments: [environment]
      )
    }
  }

  public func markTapRepositoriesRegistered(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws {
    guard !repoDids.isEmpty else { return }
    let timestamp = Self.isoString(from: at)
    try await db.write { db in
      for repoDid in repoDids {
        try db.execute(
          sql: """
            INSERT INTO appview_tap_repository_registrations
              (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
            VALUES (?, ?, 1, ?, NULL, ?)
            ON CONFLICT (environment, repo_did) DO UPDATE SET
              is_registered = 1,
              registered_at = excluded.registered_at,
              removed_at = NULL,
              updated_at = excluded.updated_at
            """,
          arguments: [environment, repoDid, timestamp, timestamp]
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
    let timestamp = Self.isoString(from: at)
    try await db.write { db in
      for repoDid in repoDids {
        try db.execute(
          sql: """
            INSERT INTO appview_tap_repository_registrations
              (environment, repo_did, is_registered, registered_at, removed_at, updated_at)
            VALUES (?, ?, 0, NULL, ?, ?)
            ON CONFLICT (environment, repo_did) DO UPDATE SET
              is_registered = 0,
              removed_at = excluded.removed_at,
              updated_at = excluded.updated_at
            """,
          arguments: [environment, repoDid, timestamp, timestamp]
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
    let eventTimeIso = eventTime.map { Self.isoString(from: $0) }
    let observedAtIso = Self.isoString(from: observedAt)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_checkpoints
            (environment, source, repo_did, collection, cursor, event_time, observed_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, source, repo_did, collection) DO UPDATE SET
            cursor = excluded.cursor,
            event_time = excluded.event_time,
            observed_at = excluded.observed_at
          """,
        arguments: [
          environment,
          source,
          repoDid,
          collection,
          cursor,
          eventTimeIso,
          observedAtIso,
        ]
      )
    }
  }

  public func fetchTapRepositorySyncState(
    environment: String,
    repoDid: String
  ) async throws -> TapRepositorySyncState? {
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT repo_rev, account_status, pds_base, last_event_id, last_event_live,
                 parity_status, matched_event_count, mismatched_event_count,
                 last_mismatch, last_indexed_at, last_validated_at, updated_at
          FROM appview_tap_repo_state
          WHERE environment = ? AND repo_did = ?
          LIMIT 1
          """,
        arguments: [environment, repoDid]
      ) else { return nil }
      guard
        let accountStatus = TapAccountStatus(rawValue: row["account_status"]),
        let parityStatus = TapParityStatus(rawValue: row["parity_status"]),
        let updatedAt = Self.date(fromIso: row["updated_at"])
      else { return nil }
      let liveInteger: Int? = row["last_event_live"]
      return TapRepositorySyncState(
        environment: environment,
        repoDid: repoDid,
        repoRev: row["repo_rev"],
        accountStatus: accountStatus,
        pdsBase: row["pds_base"],
        lastEventId: row["last_event_id"],
        lastEventLive: liveInteger.map { $0 != 0 } ?? false,
        parityStatus: parityStatus,
        matchedEventCount: row["matched_event_count"],
        mismatchedEventCount: row["mismatched_event_count"],
        lastMismatch: row["last_mismatch"],
        lastIndexedAt: (row["last_indexed_at"] as String?).flatMap(Self.date(fromIso:)),
        lastValidatedAt: (row["last_validated_at"] as String?).flatMap(Self.date(fromIso:)),
        updatedAt: updatedAt
      )
    }
  }

  public func upsertTapRepositorySyncState(_ state: TapRepositorySyncState) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_tap_repo_state
            (environment, repo_did, repo_rev, account_status, pds_base,
             last_event_id, last_event_live, parity_status, matched_event_count,
             mismatched_event_count, last_mismatch, last_indexed_at,
             last_validated_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            repo_rev = excluded.repo_rev,
            account_status = excluded.account_status,
            pds_base = excluded.pds_base,
            last_event_id = excluded.last_event_id,
            last_event_live = excluded.last_event_live,
            parity_status = excluded.parity_status,
            matched_event_count = excluded.matched_event_count,
            mismatched_event_count = excluded.mismatched_event_count,
            last_mismatch = excluded.last_mismatch,
            last_indexed_at = excluded.last_indexed_at,
            last_validated_at = excluded.last_validated_at,
            updated_at = excluded.updated_at
          """,
        arguments: [
          state.environment,
          state.repoDid,
          state.repoRev,
          state.accountStatus.rawValue,
          state.pdsBase,
          state.lastEventId,
          state.lastEventLive ? 1 : 0,
          state.parityStatus.rawValue,
          state.matchedEventCount,
          state.mismatchedEventCount,
          state.lastMismatch,
          state.lastIndexedAt.map(Self.isoString(from:)),
          state.lastValidatedAt.map(Self.isoString(from:)),
          Self.isoString(from: state.updatedAt),
        ]
      )
    }
  }

  public func hasProcessedTapEvent(environment: String, eventId: Int64) async throws -> Bool {
    try await db.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM appview_tap_event_receipts
            WHERE environment = ? AND event_id = ?
          )
          """,
        arguments: [environment, eventId]
      ) ?? false
    }
  }

  public func commitTapEvent(
    state: TapRepositorySyncState,
    eventId: Int64,
    eventType: String,
    parityEvidence: TapParityEventEvidence?,
    processedAt: Date
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO appview_tap_repo_state
            (environment, repo_did, repo_rev, account_status, pds_base,
             last_event_id, last_event_live, parity_status, matched_event_count,
             mismatched_event_count, last_mismatch, last_indexed_at,
             last_validated_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, repo_did) DO UPDATE SET
            repo_rev = excluded.repo_rev,
            account_status = excluded.account_status,
            pds_base = excluded.pds_base,
            last_event_id = excluded.last_event_id,
            last_event_live = excluded.last_event_live,
            parity_status = excluded.parity_status,
            matched_event_count = excluded.matched_event_count,
            mismatched_event_count = excluded.mismatched_event_count,
            last_mismatch = excluded.last_mismatch,
            last_indexed_at = excluded.last_indexed_at,
            last_validated_at = excluded.last_validated_at,
            updated_at = excluded.updated_at
          """,
        arguments: Self.tapStateArguments(state)
      )
      try db.execute(
        sql: """
          INSERT INTO appview_tap_event_receipts
            (environment, event_id, repo_did, event_type, processed_at, expires_at)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, event_id) DO NOTHING
          """,
        arguments: [
          state.environment,
          eventId,
          state.repoDid,
          eventType,
          Self.isoString(from: processedAt),
          Self.isoString(from: processedAt.addingTimeInterval(30 * 86_400)),
        ]
      )
      if let parityEvidence {
        if let mismatchKind = parityEvidence.mismatchKind {
          try db.execute(
            sql: """
              INSERT INTO appview_tap_parity_discrepancies
                (environment, event_id, repo_did, uri, collection, mismatch_kind,
                 expected_cid, observed_cid, status, opened_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', ?)
              ON CONFLICT (environment, event_id) DO NOTHING
              """,
            arguments: [
              state.environment, eventId, state.repoDid, parityEvidence.uri,
              parityEvidence.collection, mismatchKind, parityEvidence.expectedCid,
              parityEvidence.observedCid, Self.isoString(from: processedAt),
            ]
          )
        } else {
          try db.execute(
            sql: """
              UPDATE appview_tap_parity_discrepancies
              SET status = 'resolved', resolved_at = ?, resolution_event_id = ?
              WHERE environment = ? AND repo_did = ? AND uri = ? AND status = 'open'
              """,
            arguments: [
              Self.isoString(from: processedAt), eventId, state.environment, state.repoDid,
              parityEvidence.uri,
            ]
          )
        }
        let openCount = try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM appview_tap_parity_discrepancies
            WHERE environment = ? AND repo_did = ? AND status = 'open'
            """,
          arguments: [state.environment, state.repoDid]
        ) ?? 0
        try db.execute(
          sql: """
            UPDATE appview_tap_repo_state
            SET parity_status = ?,
                last_mismatch = CASE WHEN ? = 0 THEN NULL ELSE last_mismatch END
            WHERE environment = ? AND repo_did = ?
            """,
          arguments: [
            openCount == 0 ? TapParityStatus.matched.rawValue : TapParityStatus.mismatch.rawValue,
            openCount, state.environment, state.repoDid,
          ]
        )
      }
    }
  }

  public func listTapParityDiscrepancies(
    environment: String,
    repoDid: String
  ) async throws -> [TapParityDiscrepancy] {
    try await db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, uri, collection, mismatch_kind, expected_cid, observed_cid,
                 status, opened_at, resolved_at, resolution_event_id
          FROM appview_tap_parity_discrepancies
          WHERE environment = ? AND repo_did = ?
          ORDER BY event_id
          """,
        arguments: [environment, repoDid]
      ).compactMap { row in
        guard
          let status = TapParityDiscrepancyStatus(rawValue: row["status"]),
          let openedAt = Self.date(fromIso: row["opened_at"])
        else { return nil }
        let resolvedRaw: String? = row["resolved_at"]
        return TapParityDiscrepancy(
          environment: environment,
          eventId: row["event_id"],
          repoDid: repoDid,
          uri: row["uri"],
          collection: row["collection"],
          mismatchKind: row["mismatch_kind"],
          expectedCid: row["expected_cid"],
          observedCid: row["observed_cid"],
          status: status,
          openedAt: openedAt,
          resolvedAt: resolvedRaw.flatMap(Self.date(fromIso:)),
          resolutionEventId: row["resolution_event_id"]
        )
      }
    }
  }

  public func applyTapContentMutation(
    _ mutation: TapContentMutation,
    environment: String,
    eventId: Int64,
    repoRev: String,
    eventTime: Date,
    observedAt: Date
  ) async throws {
    try await db.write { db in
      let publicationSite: String?
      let action: String
      switch mutation {
      case .upsert(let item):
        publicationSite = item.publicationSite
        action = "upsert"
        try db.execute(
          sql: """
            INSERT INTO content_items
              (uri, cid, author_did, collection, created_at, indexed_at,
               publication_site, render_json, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (uri) DO UPDATE SET
              cid = excluded.cid,
              author_did = excluded.author_did,
              collection = excluded.collection,
              created_at = excluded.created_at,
              indexed_at = excluded.indexed_at,
              publication_site = excluded.publication_site,
              render_json = excluded.render_json,
              expires_at = excluded.expires_at
            """,
          arguments: [
            item.uri,
            item.cid,
            item.authorDid,
            item.collection,
            Self.isoString(from: item.createdAt),
            Self.isoString(from: item.indexedAt),
            item.publicationSite,
            try item.render.encodedJSON(),
            Self.isoString(from: item.expiresAt),
          ]
        )
      case .delete(let uri, _, _):
        publicationSite = try String.fetchOne(
          db,
          sql: "SELECT publication_site FROM content_items WHERE uri = ?",
          arguments: [uri]
        )
        action = "delete"
        try db.execute(sql: "DELETE FROM content_items WHERE uri = ?", arguments: [uri])
      }

      try db.execute(
        sql: """
          INSERT INTO appview_ingestion_checkpoints
            (environment, source, repo_did, collection, cursor, event_time, observed_at)
          VALUES (?, 'tap', ?, ?, ?, ?, ?)
          ON CONFLICT (environment, source, repo_did, collection) DO UPDATE SET
            cursor = excluded.cursor,
            event_time = excluded.event_time,
            observed_at = excluded.observed_at
          """,
        arguments: [
          environment,
          mutation.authorDid,
          mutation.collection,
          String(eventId),
          Self.isoString(from: eventTime),
          Self.isoString(from: observedAt),
        ]
      )

      let repairId = "\(environment):\(eventId)"
      let nowIso = Self.isoString(from: observedAt)
      try db.execute(
        sql: """
          INSERT INTO appview_projection_repair_outbox
            (id, environment, event_id, uri, author_did, publication_site, action,
             status, attempts, next_attempt_at, created_at, updated_at, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?, ?, ?, ?)
          ON CONFLICT (environment, event_id) DO NOTHING
          """,
        arguments: [
          repairId,
          environment,
          eventId,
          mutation.uri,
          mutation.authorDid,
          publicationSite,
          action,
          nowIso,
          nowIso,
          nowIso,
          Self.isoString(from: observedAt.addingTimeInterval(30 * 86_400)),
        ]
      )
      _ = repoRev
    }
  }

  public func projectionRepairBacklog(
    environment: String,
    at: Date
  ) async throws -> AppViewProjectionRepairBacklogSnapshot {
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            COUNT(CASE WHEN status = 'queued' THEN 1 END) AS queued_count,
            COUNT(CASE WHEN status = 'running' THEN 1 END) AS running_count,
            COUNT(CASE WHEN status = 'failed' THEN 1 END) AS failed_count,
            MIN(CASE WHEN status IN ('queued', 'running', 'failed') THEN created_at END)
              AS oldest_actionable_at
          FROM appview_projection_repair_outbox
          WHERE environment = ?
          """,
        arguments: [environment]
      ) else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }

      let queuedCount: Int = row["queued_count"]
      let runningCount: Int = row["running_count"]
      let failedCount: Int = row["failed_count"]
      let hasActionableRepairs = queuedCount > 0 || runningCount > 0 || failedCount > 0
      let oldestRaw: String? = row["oldest_actionable_at"]
      let oldestActionableAt = oldestRaw.flatMap(Self.date(fromIso:))

      guard queuedCount >= 0, runningCount >= 0, failedCount >= 0 else {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }
      if hasActionableRepairs {
        guard oldestRaw != nil, let oldestActionableAt, oldestActionableAt <= at else {
          throw AppViewProjectionRepairError.invalidBacklogEvidence
        }
      } else if oldestRaw != nil {
        throw AppViewProjectionRepairError.invalidBacklogEvidence
      }

      return AppViewProjectionRepairBacklogSnapshot(
        environment: environment,
        queuedCount: queuedCount,
        runningCount: runningCount,
        failedCount: failedCount,
        oldestActionableAt: oldestActionableAt,
        oldestActionableAgeSeconds: oldestActionableAt.map { at.timeIntervalSince($0) },
        observedAt: at
      )
    }
  }

  public func claimProjectionRepair(
    environment: String,
    workerId: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> AppViewProjectionRepair? {
    try await db.write { db in
      let atIso = Self.isoString(from: at)
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT id, environment, event_id, uri, author_did, publication_site,
                 action, attempts
          FROM appview_projection_repair_outbox
          WHERE environment = ?
            AND ((status = 'queued' AND next_attempt_at <= ?)
              OR (status = 'running' AND lease_until <= ?))
          ORDER BY created_at ASC
          LIMIT 1
          """,
        arguments: [environment, atIso, atIso]
      ) else { return nil }
      let id: String = row["id"]
      try db.execute(
        sql: """
          UPDATE appview_projection_repair_outbox
          SET status = 'running', lease_owner = ?, lease_until = ?, updated_at = ?
          WHERE environment = ? AND id = ?
          """,
        arguments: [workerId, Self.isoString(from: leaseUntil), atIso, environment, id]
      )
      return AppViewProjectionRepair(
        id: id,
        environment: row["environment"],
        eventId: row["event_id"],
        uri: row["uri"],
        authorDid: row["author_did"],
        publicationSite: row["publication_site"],
        action: row["action"],
        attempts: row["attempts"],
        leaseOwner: workerId,
        leaseUntil: leaseUntil
      )
    }
  }

  public func completeProjectionRepair(
    environment: String,
    id: String,
    workerId: String
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          DELETE FROM appview_projection_repair_outbox
          WHERE environment = ? AND id = ? AND status = 'running' AND lease_owner = ?
          """,
        arguments: [environment, id, workerId]
      )
      guard db.changesCount == 1 else { throw AppViewProjectionRepairError.staleLease }
    }
  }

  public func failProjectionRepair(
    environment: String,
    id: String,
    workerId: String,
    errorCategory: String,
    retryAt: Date,
    at: Date
  ) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          UPDATE appview_projection_repair_outbox
          SET attempts = attempts + 1,
              status = CASE WHEN attempts + 1 >= 5 THEN 'failed' ELSE 'queued' END,
              lease_owner = NULL,
              lease_until = NULL,
              next_attempt_at = ?,
              last_error = ?,
              updated_at = ?
          WHERE environment = ? AND id = ? AND status = 'running' AND lease_owner = ?
          """,
        arguments: [
          Self.isoString(from: retryAt), errorCategory, Self.isoString(from: at),
          environment, id, workerId,
        ]
      )
      guard db.changesCount == 1 else { throw AppViewProjectionRepairError.staleLease }
    }
  }

  public func listAuthorDidsForProactiveBackfill(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 500))
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT author_did
          FROM content_items
          WHERE author_did LIKE 'did:%' AND author_did NOT LIKE 'did:web:%'
          GROUP BY author_did
          ORDER BY MAX(indexed_at) ASC
          LIMIT ?
          """,
        arguments: [capped]
      )
      return rows.compactMap { $0["author_did"] as String? }
    }
  }

  public func listRssPublicationSites(limit: Int) async throws -> [String] {
    let capped = max(1, min(limit, 200))
    let nowIso = Self.isoString(from: Date())
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT publication_site
          FROM content_items
          WHERE author_did = ?
            AND publication_site IS NOT NULL
            AND expires_at > ?
          GROUP BY publication_site
          ORDER BY MIN(indexed_at) ASC
          LIMIT ?
          """,
        arguments: [RssFeedLexicons.rssAuthorDid, nowIso, capped]
      )
      return rows.compactMap { $0["publication_site"] as String? }
    }
  }

  public func fetchRssFeedMetadata(normalizedFeedUrl: String) async throws -> RssFeedFetchMetadata? {
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT etag, last_modified, last_poll_at, backoff_until, consecutive_error_count
          FROM rss_feed_fetch_metadata
          WHERE feed_url = ?
          LIMIT 1
          """,
        arguments: [normalizedFeedUrl]
      ) else {
        return nil
      }
      return RssFeedFetchMetadata(
        normalizedFeedUrl: normalizedFeedUrl,
        etag: row["etag"] as String?,
        lastModified: row["last_modified"] as String?,
        lastPollAt: (row["last_poll_at"] as String?).flatMap(Self.date(fromIso:)),
        backoffUntil: (row["backoff_until"] as String?).flatMap(Self.date(fromIso:)),
        consecutiveErrorCount: row["consecutive_error_count"]
      )
    }
  }

  public func storeRssFeedMetadata(_ metadata: RssFeedFetchMetadata) async throws {
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO rss_feed_fetch_metadata
            (feed_url, etag, last_modified, last_poll_at, backoff_until, consecutive_error_count)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (feed_url) DO UPDATE SET
            etag = excluded.etag,
            last_modified = excluded.last_modified,
            last_poll_at = excluded.last_poll_at,
            backoff_until = excluded.backoff_until,
            consecutive_error_count = excluded.consecutive_error_count
          """,
        arguments: [
          metadata.normalizedFeedUrl,
          metadata.etag,
          metadata.lastModified,
          metadata.lastPollAt.map { Self.isoString(from: $0) },
          metadata.backoffUntil.map { Self.isoString(from: $0) },
          metadata.consecutiveErrorCount,
        ]
      )
    }
  }

  private func publicationScopes(
    authorDid: String,
    viewerDid: String?
  ) async throws -> [AppViewPublicationScope] {
    try await db.read { db in
      var sql = """
        SELECT viewer_did, publication_id, author_did, publication_at_uri,
               publication_scope_at_uris, publication_site_urls, scope_keys,
               section_keys, updated_at
        FROM appview_publication_scopes
        WHERE author_did = ?
        """
      var args: [DatabaseValueConvertible?] = [authorDid]
      if let viewerDid {
        sql += " AND viewer_did = ?"
        args.append(viewerDid)
      }
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
      return rows.compactMap(Self.publicationScope(from:))
    }
  }

  private func readFloors(
    viewerDid: String,
    publicationIds: [String]
  ) async throws -> [String: Date] {
    let uniqueIds = Array(Set(publicationIds)).sorted()
    guard !uniqueIds.isEmpty else { return [:] }
    return try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT publication_id, read_floor_at
          FROM appview_publication_read_floors
          WHERE viewer_did = ?
            AND publication_id IN (\(uniqueIds.map { _ in "?" }.joined(separator: ", ")))
          """,
        arguments: StatementArguments([viewerDid] + uniqueIds)
      )
      var floors: [String: Date] = [:]
      for row in rows {
        let publicationId: String = row["publication_id"]
        if let floor = Self.date(fromIso: row["read_floor_at"]) {
          floors[publicationId] = floor
        }
      }
      return floors
    }
  }

  private func countUnreadEntriesAfterFloor(
    viewerDid: String,
    scope: PublicationUnreadScope,
    readFloorAt: Date
  ) async throws -> Int {
    let nowIso = Self.isoString(from: Date())
    let floorIso = Self.isoString(from: readFloorAt)
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
      return try await db.read { db in
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*)
            FROM content_items ci
            LEFT JOIN read_marks rm
              ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
            WHERE ci.author_did = ?
              AND ci.expires_at > ?
              AND ci.created_at > ?
              AND ci.publication_site IN (\(siteKeys.map { _ in "?" }.joined(separator: ", ")))
              AND rm.subject_uri IS NULL
            """,
          arguments: StatementArguments([viewerDid, scope.authorDid, nowIso, floorIso] + siteKeys)
        ) ?? 0
      }
    }

    let siteFields: [String?] = try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ci.publication_site
          FROM content_items ci
          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          WHERE ci.author_did = ?
            AND ci.expires_at > ?
            AND ci.created_at > ?
            AND rm.subject_uri IS NULL
          """,
        arguments: [viewerDid, scope.authorDid, nowIso, floorIso]
      )
      return rows.map { $0["publication_site"] as String? }
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
    try await db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT author_did, publication_site, created_at
          FROM content_items
          WHERE uri = ?
          LIMIT 1
          """,
        arguments: [uri]
      ) else {
        return nil
      }
      return (
        authorDid: row["author_did"],
        publicationSite: row["publication_site"] as String?,
        createdAt: Self.date(fromIso: row["created_at"]) ?? Date.distantPast
      )
    }
  }

  private static func publicationScope(from row: Row) -> AppViewPublicationScope? {
    guard
      let updatedAt = date(fromIso: row["updated_at"]),
      let publicationScopeAtUris = try? stringArray(fromJSON: row["publication_scope_at_uris"]),
      let publicationSiteUrls = try? stringArray(fromJSON: row["publication_site_urls"]),
      let scopeKeys = try? stringArray(fromJSON: row["scope_keys"]),
      let sectionKeys = try? stringArray(fromJSON: row["section_keys"])
    else { return nil }
    return AppViewPublicationScope(
      viewerDid: row["viewer_did"],
      publicationId: row["publication_id"],
      authorDid: row["author_did"],
      publicationAtUri: row["publication_at_uri"] as String?,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      scopeKeys: scopeKeys,
      sectionKeys: sectionKeys,
      updatedAt: updatedAt
    )
  }

  private static func unreadCounter(from row: Row) -> AppViewUnreadCounter? {
    guard
      let countedAt = date(fromIso: row["counted_at"]),
      let accuracy = AppViewUnreadCounterAccuracy(rawValue: row["accuracy"])
    else { return nil }
    return AppViewUnreadCounter(
      publicationId: row["publication_id"],
      unreadCount: row["unread_count"],
      generation: Int64(row["generation"] as Int),
      accuracy: accuracy,
      dirty: (row["dirty"] as Int) != 0,
      countedAt: countedAt
    )
  }

  private static func upsertUnreadCounter(
    _ counter: AppViewUnreadCounter,
    viewerDid: String,
    countedAtIso: String,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO appview_unread_counters
          (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
          unread_count = excluded.unread_count,
          generation = excluded.generation,
          accuracy = excluded.accuracy,
          dirty = excluded.dirty,
          counted_at = excluded.counted_at
        """,
      arguments: [
        viewerDid,
        counter.publicationId,
        counter.unreadCount,
        counter.generation,
        counter.accuracy.rawValue,
        counter.dirty ? 1 : 0,
        countedAtIso,
      ]
    )
  }

  private static func adjustUnreadCounter(
    viewerDid: String,
    publicationId: String,
    delta: Int,
    generation: Int64,
    countedAtIso: String,
    db: Database
  ) throws {
    let current = try Int.fetchOne(
      db,
      sql: """
        SELECT unread_count
        FROM appview_unread_counters
        WHERE viewer_did = ? AND publication_id = ?
        LIMIT 1
        """,
      arguments: [viewerDid, publicationId]
    ) ?? 0
    let next = max(0, current + delta)
    try db.execute(
      sql: """
        INSERT INTO appview_unread_counters
          (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
        VALUES (?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
          unread_count = excluded.unread_count,
          generation = excluded.generation,
          accuracy = excluded.accuracy,
          dirty = 1,
          counted_at = excluded.counted_at
        """,
      arguments: [
        viewerDid,
        publicationId,
        next,
        generation,
        AppViewUnreadCounterAccuracy.estimated.rawValue,
        countedAtIso,
      ]
    )
  }

  private static func markUnreadCounterDirty(
    viewerDid: String,
    publicationId: String,
    generation: Int64,
    countedAtIso: String,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO appview_unread_counters
          (viewer_did, publication_id, unread_count, generation, accuracy, dirty, counted_at)
        VALUES (?, ?, 0, ?, ?, 1, ?)
        ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
          generation = excluded.generation,
          accuracy = excluded.accuracy,
          dirty = 1,
          counted_at = excluded.counted_at
        """,
      arguments: [
        viewerDid,
        publicationId,
        generation,
        AppViewUnreadCounterAccuracy.estimated.rawValue,
        countedAtIso,
      ]
    )
  }

  private static func readFloor(
    viewerDid: String,
    publicationId: String,
    db: Database
  ) throws -> Date? {
    guard let raw = try String.fetchOne(
      db,
      sql: """
        SELECT read_floor_at
        FROM appview_publication_read_floors
        WHERE viewer_did = ? AND publication_id = ?
        LIMIT 1
        """,
      arguments: [viewerDid, publicationId]
    ) else {
      return nil
    }
    return date(fromIso: raw)
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

  private static func tapStateArguments(_ state: TapRepositorySyncState) -> StatementArguments {
    [
      state.environment,
      state.repoDid,
      state.repoRev,
      state.accountStatus.rawValue,
      state.pdsBase,
      state.lastEventId,
      state.lastEventLive ? 1 : 0,
      state.parityStatus.rawValue,
      state.matchedEventCount,
      state.mismatchedEventCount,
      state.lastMismatch,
      state.lastIndexedAt.map(isoString(from:)),
      state.lastValidatedAt.map(isoString(from:)),
      isoString(from: state.updatedAt),
    ]
  }

  private static func isoString(from date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func date(fromIso raw: String) -> Date? {
    ISO8601DateFormatter().date(from: raw)
  }
}
