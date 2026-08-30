import Foundation
import Logging
import PostgresNIO
import WireCore

actor PostgresCirclePrivateStateStore: CirclePrivateStateStoring {
  private let pool: PostgresClient
  private let actorHasher: WireActorHasher
  private let logger: Logger
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(pool: PostgresClient, actorHasher: WireActorHasher, logger: Logger) {
    self.pool = pool
    self.actorHasher = actorHasher
    self.logger = logger
    self.encoder = JSONEncoder()
    self.encoder.dateEncodingStrategy = .iso8601
    self.decoder = JSONDecoder()
    self.decoder.dateDecodingStrategy = .iso8601
  }

  func load(viewerDID: String, excludedDIDs: Set<String>) async throws -> CircleGraphSnapshot? {
    let viewerHash = try actorHasher.hash(viewerDID)
    let exclusionDigest = Self.exclusionDigest(excludedDIDs)
    let rows = try await pool.query(
      """
      SELECT actor_facts::text
      FROM appview_circle_graph_snapshots
      WHERE viewer_key_hash = \(viewerHash) AND graph_digest = \(exclusionDigest)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try decoder.decode(CircleGraphSnapshot.self, from: Data(row.decode(String.self).utf8))
    }
    return nil
  }

  func store(_ snapshot: CircleGraphSnapshot, excludedDIDs: Set<String>) async throws {
    let viewerHash = try actorHasher.hash(snapshot.viewerDID)
    let exclusionDigest = Self.exclusionDigest(excludedDIDs)
    let payload = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    let freshUntil = snapshot.generatedAt.addingTimeInterval(CircleGraphSnapshotService.freshTarget)
    let staleUntil = snapshot.generatedAt.addingTimeInterval(
      CircleGraphSnapshotService.staleMaximum)
    _ = try await pool.query(
      """
      INSERT INTO appview_circle_graph_snapshots
        (viewer_key_hash, snapshot_id, graph_digest, direct_count, one_hop_count,
         actor_facts, generated_at, fresh_until, stale_until)
      VALUES
        (\(viewerHash), \(snapshot.snapshotID), \(exclusionDigest),
         \(snapshot.directMembers.count), \(snapshot.oneHopMembers.count),
         CAST(\(payload) AS jsonb), \(snapshot.generatedAt), \(freshUntil), \(staleUntil))
      ON CONFLICT (viewer_key_hash) DO UPDATE SET
        snapshot_id = EXCLUDED.snapshot_id,
        graph_digest = EXCLUDED.graph_digest,
        direct_count = EXCLUDED.direct_count,
        one_hop_count = EXCLUDED.one_hop_count,
        actor_facts = EXCLUDED.actor_facts,
        generated_at = EXCLUDED.generated_at,
        fresh_until = EXCLUDED.fresh_until,
        stale_until = EXCLUDED.stale_until
      """,
      logger: logger
    )
  }

  func hiddenStoryIDs(viewerDID: String) async throws -> Set<String> {
    let viewerHash = try actorHasher.hash(viewerDID)
    let rows = try await pool.query(
      "SELECT canonical_key FROM appview_circle_hidden_items WHERE viewer_key_hash = \(viewerHash)",
      logger: logger
    )
    var result = Set<String>()
    for try await row in rows { result.insert(try row.decode(String.self)) }
    return result
  }

  func setHidden(viewerDID: String, storyID: String, hidden: Bool, now: Date) async throws {
    let viewerHash = try actorHasher.hash(viewerDID)
    if hidden {
      _ = try await pool.query(
        """
        INSERT INTO appview_circle_hidden_items (viewer_key_hash, canonical_key, hidden_at)
        VALUES (\(viewerHash), \(storyID), \(now))
        ON CONFLICT (viewer_key_hash, canonical_key) DO UPDATE SET hidden_at = EXCLUDED.hidden_at
        """,
        logger: logger
      )
    } else {
      _ = try await pool.query(
        """
        DELETE FROM appview_circle_hidden_items
        WHERE viewer_key_hash = \(viewerHash) AND canonical_key = \(storyID)
        """,
        logger: logger
      )
    }
    _ = try await pool.query(
      "DELETE FROM appview_circle_edition_cache WHERE viewer_key_hash = \(viewerHash)",
      logger: logger
    )
  }

  func cachedEdition(
    viewerDID: String,
    snapshotID: UUID,
    generationID: String,
    language: String,
    now: Date
  ) async throws -> Data? {
    let viewerHash = try actorHasher.hash(viewerDID)
    let rows = try await pool.query(
      """
      SELECT payload::text FROM appview_circle_edition_cache
      WHERE viewer_key_hash = \(viewerHash) AND snapshot_id = \(snapshotID)
        AND generation_id = \(generationID) AND language_code = \(language)
        AND expires_at > \(now)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows { return Data(try row.decode(String.self).utf8) }
    return nil
  }

  func storeEdition(
    viewerDID: String,
    snapshotID: UUID,
    generationID: String,
    language: String,
    expiresAt: Date,
    payload: Data
  ) async throws {
    let viewerHash = try actorHasher.hash(viewerDID)
    let json = String(decoding: payload, as: UTF8.self)
    _ = try await pool.query(
      """
      INSERT INTO appview_circle_edition_cache
        (viewer_key_hash, snapshot_id, generation_id, language_code, expires_at, payload)
      VALUES (\(viewerHash), \(snapshotID), \(generationID), \(language), \(expiresAt), CAST(\(json) AS jsonb))
      ON CONFLICT (viewer_key_hash, snapshot_id, generation_id, language_code)
      DO UPDATE SET expires_at = EXCLUDED.expires_at, payload = EXCLUDED.payload, created_at = NOW()
      """,
      logger: logger
    )
  }

  func purge(viewerDID: String) async throws {
    let viewerHash = try actorHasher.hash(viewerDID)
    try await pool.withTransaction(logger: logger) { transaction in
      _ = try await transaction.query(
        "DELETE FROM appview_circle_edition_cache WHERE viewer_key_hash = \(viewerHash)",
        logger: logger
      )
      _ = try await transaction.query(
        "DELETE FROM appview_circle_hidden_items WHERE viewer_key_hash = \(viewerHash)",
        logger: logger
      )
      _ = try await transaction.query(
        "DELETE FROM appview_circle_graph_snapshots WHERE viewer_key_hash = \(viewerHash)",
        logger: logger
      )
    }
  }

  private static func exclusionDigest(_ excludedDIDs: Set<String>) -> String {
    WireCorpusServiceTrust.bodyDigest(Data(excludedDIDs.sorted().joined(separator: "\n").utf8))
  }
}
