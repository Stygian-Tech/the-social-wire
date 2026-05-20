@preconcurrency import GRDB
import Foundation
import Logging

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
    let nowIso = Self.isoString(from: Date())
    let pageLimit = max(1, min(limit, 100))
    let scoped = publicationAtUri != nil || !publicationScopeAtUris.isEmpty
    let fetchLimit = scoped ? (pageLimit + 1) * 8 : pageLimit + 1

    let rows: [(uri: String, renderJSON: String, createdAt: Date, publicationSite: String?)] =
      try await db.read { db in
        var sql = """
          SELECT ci.uri, ci.render_json, ci.created_at, ci.publication_site
          FROM content_items ci
          LEFT JOIN read_marks rm
            ON rm.viewer_did = ? AND rm.subject_uri = ci.uri
          WHERE ci.author_did = ?
            AND ci.expires_at > ?
          """

        var args: [DatabaseValueConvertible?] = [viewerDid, authorDid, nowIso]

        switch filter {
        case .all:
          break
        case .unread:
          sql += " AND rm.subject_uri IS NULL"
        case .read:
          sql += " AND rm.subject_uri IS NOT NULL"
        }

        if let decoded = cursor.flatMap({ ThinAppViewCursor.decode($0) }) {
          sql += " AND (ci.created_at < ? OR (ci.created_at = ? AND ci.uri < ?))"
          let createdIso = Self.isoString(from: decoded.createdAt)
          args.append(contentsOf: [createdIso, createdIso, decoded.uri])
        }

        sql += " ORDER BY ci.created_at DESC, ci.uri DESC LIMIT ?"
        args.append(fetchLimit)

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

    let filtered = rows.filter { row in
      ThinAppViewQuerySupport.publicationSiteMatches(
        siteField: row.publicationSite,
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls
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

  public func deleteExpiredContent(before: Date) async throws -> Int {
    let beforeIso = Self.isoString(from: before)
    return try await db.write { db in
      try db.execute(
        sql: "DELETE FROM content_items WHERE expires_at <= ?",
        arguments: [beforeIso]
      )
      return db.changesCount
    }
  }

  public func deleteExpiredReadMarks(before: Date) async throws -> Int {
    let beforeIso = Self.isoString(from: before)
    return try await db.write { db in
      try db.execute(
        sql: "DELETE FROM read_marks WHERE created_at <= ?",
        arguments: [beforeIso]
      )
      return db.changesCount
    }
  }

  private static func isoString(from date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func date(fromIso raw: String) -> Date? {
    ISO8601DateFormatter().date(from: raw)
  }
}
