import Foundation
import Logging
import PostgresNIO
import WireCore

actor PostgresCirclePrivateStateStore: CirclePrivateStateStoring {
  private let pool: PostgresClient
  private let actorHasher: WireActorHasher
  private let logger: Logger
  private let cache: (any CircleDisposableCaching)?

  init(
    pool: PostgresClient,
    cache: (any CircleDisposableCaching)? = nil,
    actorHasher: WireActorHasher,
    logger: Logger
  ) {
    self.pool = pool
    self.cache = cache
    self.actorHasher = actorHasher
    self.logger = logger
  }

  func load(viewerDID: String, excludedDIDs: Set<String>) async throws -> CircleGraphSnapshot? {
    try await cache?.load(viewerDID: viewerDID, excludedDIDs: excludedDIDs)
  }

  func store(_ snapshot: CircleGraphSnapshot, excludedDIDs: Set<String>) async throws {
    try await cache?.store(snapshot, excludedDIDs: excludedDIDs)
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
    await cache?.invalidateEditions(viewerDID: viewerDID)
  }

  func cachedEdition(
    viewerDID: String, snapshotID: UUID, generationID: String, language: String,
    hiddenStoryIDs: Set<String>, now: Date
  ) async throws -> Data? {
    await cache?.cachedEdition(
      viewerDID: viewerDID, snapshotID: snapshotID, generationID: generationID,
      language: language, hiddenStoryIDs: hiddenStoryIDs, now: now
    )
  }

  func storeEdition(
    viewerDID: String, snapshotID: UUID, generationID: String, language: String,
    hiddenStoryIDs: Set<String>, expiresAt: Date, payload: Data
  ) async throws {
    await cache?.storeEdition(
      viewerDID: viewerDID, snapshotID: snapshotID, generationID: generationID,
      language: language, hiddenStoryIDs: hiddenStoryIDs, expiresAt: expiresAt, payload: payload
    )
  }

  func purge(viewerDID: String) async throws {
    try await cache?.purge(viewerDID: viewerDID)
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

}
