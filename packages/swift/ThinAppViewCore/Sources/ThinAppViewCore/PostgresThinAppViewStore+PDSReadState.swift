import Foundation
import PostgresNIO
import ReadStateCore

extension PostgresThinAppViewStore: PDSReadStateStoring {
  public func pdsReadStateStatus(viewerDid: String) async throws -> PDSReadStateStatus {
    for try await row in try await pool.query(
      """
      SELECT legacy_revision, manifest::text, manifest_cid, projection_ready
      FROM appview_pds_read_state_authority WHERE viewer_did = \(viewerDid)
      """, logger: logger) {
      return try Self.pdsStatus(row)
    }
    return PDSReadStateStatus(authority: .appview, migrationState: .notStarted, legacyRevision: 0)
  }

  public func exportPDSReadStatePage(
    viewerDid: String, cursor: String?, expectedLegacyRevision: Int64?, limit: Int
  ) async throws -> PDSReadStateExportPage {
    if cursor != nil && expectedLegacyRevision == nil { throw PDSReadStateStorageError.invalidCursor }
    let position = try Self.decodePDSExportCursor(cursor)
    return try await pdsReadStateTransaction { connection in
      let status = try await lockedPDSStatus(viewerDid: viewerDid, on: connection)
      guard status.authority == .appview else { throw PDSReadStateStorageError.alreadyMigrated }
      if let expectedLegacyRevision, expectedLegacyRevision != status.legacyRevision {
        throw PDSReadStateStorageError.revisionChanged
      }
      let page = try await legacyPDSPage(viewerDid: viewerDid, position: position,
        limit: max(1, min(limit, 1_000)), on: connection)
      return PDSReadStateExportPage(legacyRevision: status.legacyRevision, rows: page.rows, cursor: page.cursor)
    }
  }

  public func activatePDSReadState(
    viewerDid: String, manifest: ReadStateManifest, manifestCid: String,
    projection: ReadStateProjection, expectedLegacyRevision: Int64?
  ) async throws -> PDSReadStateStatus {
    try ReadStateValidation.validate(manifest, viewerDid: viewerDid)
    guard !manifestCid.isEmpty, projection.lastSequence == manifest.lastSequence else {
      throw ReadStateError.incompleteGeneration
    }
    let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
    return try await pdsReadStateTransaction { connection in
      let status = try await lockedPDSStatus(viewerDid: viewerDid, on: connection)
      if status.authority == .appview {
        guard expectedLegacyRevision == status.legacyRevision else {
          throw PDSReadStateStorageError.revisionChanged
        }
        try await verifyLegacyPDSParity(viewerDid: viewerDid, projection: projection, on: connection)
      } else {
        guard status.manifestCid == manifestCid
          || manifest.lastSequence > (status.manifest?.lastSequence ?? 0) else {
          throw PDSReadStateStorageError.staleGeneration
        }
      }
      // An immutable ancestor proves ordinary appends cannot change old actions.
      // Only new actions cross the database connection. Repacking/rebuilds diff
      // a complete temporary projection and suppress unchanged persistent writes.
      let previousSequence = status.manifest?.lastSequence ?? 0
      let incremental = status.manifestCid != manifestCid && status.authority == .pds && status.projectionReady
        && status.manifest?.head.map { projection.sourceReferences.contains($0) } == true
      let operations = incremental
        ? projection.operations.filter { $0.sequence > previousSequence } : projection.operations
      try await persistPDSProjection(viewerDid: viewerDid, operations: operations,
        incremental: incremental, on: connection)
      try Task.checkCancellation()
      try await connection.query(
        """
        UPDATE appview_pds_read_state_authority SET manifest = \(manifestJSON)::jsonb,
          manifest_cid = \(manifestCid), last_sequence = \(manifest.lastSequence),
          activated_at = COALESCE(activated_at, NOW()), updated_at = NOW(), projection_ready = TRUE,
          last_accessed_at = CASE WHEN manifest_cid IS NULL THEN NOW() ELSE last_accessed_at END
        WHERE viewer_did = \(viewerDid)
          AND (manifest_cid IS DISTINCT FROM \(manifestCid) OR manifest IS DISTINCT FROM \(manifestJSON)::jsonb OR NOT projection_ready)
        """, logger: logger)
      try await connection.query(
        "UPDATE appview_unread_counters SET dirty = TRUE WHERE viewer_did = \(viewerDid) AND dirty = FALSE", logger: logger)
      return PDSReadStateStatus(authority: .pds, migrationState: .verified,
        legacyRevision: status.legacyRevision, manifest: manifest, manifestCid: manifestCid)
    }
  }

  public func preparePDSReadStateBoundaries(
    viewerDid: String, scopes: [PublicationUnreadScope], at: Date
  ) async throws -> [ReadStateBoundary] {
    var result: [ReadStateBoundary] = []
    for scope in scopes.sorted(by: { $0.publicationId < $1.publicationId }) {
      let keys = AppViewProjectionCacheScopeKeys.publicationSiteKeys(
        publicationAtUri: scope.publicationAtUri, publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls)
      if keys.isEmpty && ThinAppViewQuerySupport.requiresPublicationSiteFilter(
        publicationAtUri: scope.publicationAtUri, publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls) { throw PDSReadStateStorageError.legacyScopeUnavailable }
      var requested = ReadWatermarkBoundary(publicationId: scope.publicationId, createdAt: at, entryId: nil)
      for try await row in try await pool.query(
        """
        SELECT uri, created_at FROM content_items WHERE author_did = \(scope.authorDid)
          AND created_at <= \(at) AND (\(keys.isEmpty) OR publication_site = ANY(\(keys)))
        ORDER BY created_at DESC, uri DESC LIMIT 1
        """, logger: logger) {
        let value = try row.decode((String, Date).self)
        requested = ReadWatermarkBoundary(publicationId: scope.publicationId, createdAt: value.1, entryId: value.0)
      }
      if let existing = try await readBoundary(viewerDid: viewerDid, publicationId: scope.publicationId),
         !requested.isAfter(existing) { requested = existing }
      result.append(ReadStateBoundary(scope: ReadStateScope(publicationId: scope.publicationId,
        authorDid: scope.authorDid, publicationSiteKeys: keys.sorted()),
        createdAt: Self.pdsTimestamp(requested.createdAt), entryId: requested.entryId))
    }
    return result
  }

  private func pdsReadStateTransaction<Result>(
    _ body: (PostgresConnection) async throws -> sending Result
  ) async throws -> sending Result {
    do { return try await pool.withTransaction(logger: logger, body) }
    catch let error as PostgresTransactionError {
      if let storage = error.closureError as? PDSReadStateStorageError { throw storage }
      if let validation = error.closureError as? ReadStateError { throw validation }
      throw error
    }
  }

  private func lockedPDSStatus(viewerDid: String, on connection: PostgresConnection) async throws -> PDSReadStateStatus {
    try await connection.query(
      "INSERT INTO appview_pds_read_state_authority(viewer_did) VALUES (\(viewerDid)) ON CONFLICT DO NOTHING", logger: logger)
    for try await row in try await connection.query(
      """
      SELECT legacy_revision, manifest::text, manifest_cid, projection_ready
      FROM appview_pds_read_state_authority WHERE viewer_did = \(viewerDid) FOR UPDATE
      """, logger: logger) { return try Self.pdsStatus(row) }
    throw PDSReadStateStorageError.revisionChanged
  }

  private static func pdsStatus(_ row: PostgresRow) throws -> PDSReadStateStatus {
    let value = try row.decode((Int64, String?, String?, Bool).self)
    let manifest = try value.1.map { try JSONDecoder().decode(ReadStateManifest.self, from: Data($0.utf8)) }
    return PDSReadStateStatus(authority: manifest == nil ? .appview : .pds,
      migrationState: manifest == nil ? .notStarted : .verified, legacyRevision: value.0,
      manifest: manifest, manifestCid: value.2, projectionReady: value.3)
  }

  private struct PDSExportPosition: Codable, Sendable {
    let phase: Int
    let key: String
  }

  private static func decodePDSExportCursor(_ cursor: String?) throws -> PDSExportPosition {
    guard let cursor else { return PDSExportPosition(phase: -1, key: "") }
    guard let data = Data(base64Encoded: cursor),
          let position = try? JSONDecoder().decode(PDSExportPosition.self, from: data),
          (0...2).contains(position.phase) else { throw PDSReadStateStorageError.invalidCursor }
    return position
  }

  private func legacyPDSPage(
    viewerDid: String, position: PDSExportPosition, limit: Int, on connection: PostgresConnection
  ) async throws -> (rows: [ReadStateLegacyRow], cursor: String?) {
    let query = try await connection.query(
      """
      SELECT phase, key, acted_at, boundary_at, boundary_uri, author_did, scope_keys::text
      FROM (
        SELECT 0 AS phase, floor.publication_id AS key, floor.updated_at AS acted_at,
          floor.read_floor_at AS boundary_at, floor.read_floor_uri AS boundary_uri,
          scope.author_did, scope.scope_keys
        FROM appview_publication_read_floors floor
        LEFT JOIN appview_publication_scopes scope
          ON scope.viewer_did = floor.viewer_did AND scope.publication_id = floor.publication_id
        WHERE floor.viewer_did = \(viewerDid)
        UNION ALL
        SELECT 1, subject_uri, created_at, NULL, NULL, NULL, NULL
        FROM appview_unread_overrides WHERE viewer_did = \(viewerDid)
        UNION ALL
        SELECT 2, subject_uri, created_at, NULL, NULL, NULL, NULL
        FROM read_marks WHERE viewer_did = \(viewerDid)
      ) rows
      WHERE phase > \(position.phase) OR (phase = \(position.phase) AND key COLLATE "C" > \(position.key) COLLATE "C")
      ORDER BY phase, key COLLATE "C" LIMIT \(limit + 1)
      """, logger: logger)
    var rows: [ReadStateLegacyRow] = []
    var last: PDSExportPosition?
    var more = false
    for try await row in query {
      if rows.count == limit { more = true; break }
      let value = try row.decode((Int, String, Date, Date?, String?, String?, String?).self)
      if value.0 == 0 {
        guard let boundaryAt = value.3, let author = value.5, let keys = value.6 else {
          throw PDSReadStateStorageError.legacyScopeUnavailable
        }
        rows.append(ReadStateLegacyRow(kind: .boundary, actedAt: Self.pdsTimestamp(value.2),
          boundary: ReadStateBoundary(scope: ReadStateScope(publicationId: value.1, authorDid: author,
            publicationSiteKeys: try JSONDecoder().decode([String].self, from: Data(keys.utf8)).sorted()),
            createdAt: Self.pdsTimestamp(boundaryAt), entryId: value.4)))
      } else {
        rows.append(ReadStateLegacyRow(kind: value.0 == 1 ? .unread : .read,
          actedAt: Self.pdsTimestamp(value.2), subjectUri: value.1))
      }
      last = PDSExportPosition(phase: value.0, key: value.1)
    }
    return (rows, try more ? last.map { try JSONEncoder().encode($0).base64EncodedString() } : nil)
  }

  private func verifyLegacyPDSParity(
    viewerDid: String, projection: ReadStateProjection, on connection: PostgresConnection
  ) async throws {
    // Canonical subject state cannot represent two publication views that apply
    // different floors to the same possible article. Check scopes, not only the
    // currently retained corpus: a future backfill must preserve parity too.
    for try await _ in try await connection.query(
      """
      SELECT 1
      FROM appview_publication_scopes a
      JOIN appview_publication_read_floors af
        ON af.viewer_did = a.viewer_did AND af.publication_id = a.publication_id
      JOIN appview_publication_scopes b
        ON b.viewer_did = a.viewer_did AND b.author_did = a.author_did
          AND b.publication_id <> a.publication_id
      LEFT JOIN appview_publication_read_floors bf
        ON bf.viewer_did = b.viewer_did AND bf.publication_id = b.publication_id
      WHERE a.viewer_did = \(viewerDid)
        AND (a.scope_keys = '[]'::jsonb OR b.scope_keys = '[]'::jsonb
          OR a.scope_keys ?| ARRAY(SELECT jsonb_array_elements_text(b.scope_keys)))
        AND (af.read_floor_at, af.read_floor_uri) IS DISTINCT FROM (bf.read_floor_at, bf.read_floor_uri)
      LIMIT 1
      """, logger: logger) { throw PDSReadStateStorageError.legacyScopeOverlap }
    for try await _ in try await connection.query(
      """
      SELECT 1 FROM read_marks read JOIN appview_unread_overrides unread
        ON read.viewer_did = unread.viewer_did AND read.subject_uri = unread.subject_uri
      WHERE read.viewer_did = \(viewerDid) LIMIT 1
      """, logger: logger) { throw PDSReadStateStorageError.parityMismatch }
    let operations = Dictionary(grouping: projection.operations, by: \.sequence)
    var position = PDSExportPosition(phase: -1, key: "")
    var sequence: Int64 = 0
    repeat {
      let page = try await legacyPDSPage(viewerDid: viewerDid, position: position, limit: 1_000, on: connection)
      for row in page.rows {
        sequence += 1
        guard let parts = operations[sequence], !parts.isEmpty else { throw PDSReadStateStorageError.parityMismatch }
        for part in parts {
          guard try ReadStateValidation.date(part.actedAt) == ReadStateValidation.date(row.actedAt),
                part.calendar == nil else { throw PDSReadStateStorageError.parityMismatch }
          if let boundary = row.boundary {
            guard part.state == .read, part.selection == .boundaries,
                  part.boundaries == [boundary] else { throw PDSReadStateStorageError.parityMismatch }
          } else {
            guard part.state == (row.kind == .read ? .read : .unread), part.selection == .exact,
                  part.subjectUris == [row.subjectUri!] else { throw PDSReadStateStorageError.parityMismatch }
          }
        }
      }
      guard let cursor = page.cursor else { break }
      position = try Self.decodePDSExportCursor(cursor)
    } while true
  }

  func pdsEntryReadState(viewerDid: String, subjectUri: String) async throws -> Bool {
    for try await row in try await pool.query(
      """
      SELECT COALESCE(appview_pds_entry_is_read(\(viewerDid), \(subjectUri),
        ci.author_did, ci.publication_site, ci.created_at), FALSE)
      FROM (SELECT 1) subject LEFT JOIN content_items ci ON ci.uri = \(subjectUri)
      """, logger: logger) { return try row.decode(Bool.self) }
    return false
  }

  private static func pdsTimestamp(_ date: Date) -> String {
    let microseconds = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    let formatter = ISO8601DateFormatter()
    let base = formatter.string(from: Date(timeIntervalSince1970: Double(microseconds / 1_000_000)))
    return String(base.dropLast()) + String(format: ".%06lldZ", microseconds % 1_000_000)
  }
}
