import Foundation
import PostgresNIO

extension PostgresPodcastStore {
  public func requirePrivateStorage() throws -> PodcastPrivateStorage {
    guard let privateStorage else { throw PodcastStoreError.privateStorageUnavailable }
    return privateStorage
  }
  private func privateEpisode(_ raw: String, viewer: String, id: String) throws -> PodcastEpisode {
    try decode(requirePrivateStorage().open(raw, viewer: viewer, entity: "episode", id: id), PodcastEpisode.self)
  }
  public func stalePrivateFeeds(viewer: String, limit: Int = 2) async throws -> [String] {
    guard let privateStorage else { return [] }
    let rows = try await pool.query("SELECT id,feed_data FROM podcast_private_shows WHERE viewer_did=\(viewer) AND updated_at<now()-interval '15 minutes' ORDER BY updated_at,id LIMIT \(max(0,min(limit,2)))", logger: logger)
    var feeds: [String] = []
    for try await row in rows {
      let value = try row.decode((String, String).self)
      feeds.append(try privateStorage.open(value.1, viewer: viewer, entity: "feed", id: value.0))
    }
    return feeds
  }
  public func queuedEpisodes(viewer: String) async throws -> [PodcastEpisode] {
    let queue = try await state(viewer: viewer).state.queue
    guard !queue.isEmpty else { return [] }
    let rows = try await pool.query("""
      SELECT id,episode_json::text,false FROM podcast_episodes WHERE id=ANY(\(queue))
      UNION ALL SELECT id,episode_data,true FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND id=ANY(\(queue))
      """, logger: logger)
    var episodes: [String: PodcastEpisode] = [:]
    for try await row in rows {
      let value = try row.decode((String, String, Bool).self)
      let episode = try value.2 ? privateEpisode(value.1, viewer: viewer, id: value.0) : decode(value.1, PodcastEpisode.self)
      episodes[episode.id] = episode
    }
    return queue.compactMap { episodes[$0] }
  }
  public func ownsPrivateEpisodes(viewer: String, ids: [String]) async throws -> Bool {
    guard !ids.isEmpty else { return true }
    _ = try requirePrivateStorage()
    let rows = try await pool.query("SELECT id,episode_data FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND id=ANY(\(ids))", logger: logger)
    var found = Set<String>()
    for try await row in rows {
      let value = try row.decode((String, String).self)
      _ = try privateEpisode(value.1, viewer: viewer, id: value.0)
      found.insert(value.0)
    }
    return found == Set(ids)
  }
  public func savePrivateCatalog(
    viewer: String, feedURL: String, show: PodcastShow, episodes: [PodcastEpisode], existingOnly: Bool = false
  ) async throws {
    guard PodcastPrivateCatalog.isAllowedURL(feedURL), show.visibility == "private",
      PodcastPrivateCatalog.isPrivateID(show.id),
      episodes.allSatisfy({ $0.showId == show.id && $0.visibility == "private" && PodcastPrivateCatalog.isPrivateID($0.id) })
    else { throw PodcastStoreError.invalidRequest }
    let storage = try requirePrivateStorage()
    let feedHash = PodcastRSSParser.identity(feedURL)
    let feedData = try storage.seal(feedURL, viewer: viewer, entity: "feed", id: show.id)
    let showData = try storage.seal(json(show), viewer: viewer, entity: "show", id: show.id)
    let previousRows = try await pool.query("SELECT id,episode_data FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND id=ANY(\(episodes.map(\.id)))", logger: logger)
    var previous: [String: PodcastEpisode] = [:]
    for try await row in previousRows {
      let value = try row.decode((String, String).self)
      previous[value.0] = try privateEpisode(value.1, viewer: viewer, id: value.0)
    }
    let entries = try episodes.map { original in
      var episode = original
      if let existing = previous[episode.id], episode.chapters.isEmpty,
        episode.chapterSourceUrl == existing.chapterSourceUrl { episode.chapters = existing.chapters }
      return (episode.id, try storage.seal(json(episode), viewer: viewer, entity: "episode", id: episode.id), ISO8601DateFormatter().date(from: episode.publishedAt) ?? Date(timeIntervalSince1970: 0))
    }
    let logger = logger
    do {
      try await pool.withTransaction(logger: logger) { connection in
        // Serialize refresh with deletion: a refresh may update a subscription but never recreate one.
        let rows = try await connection.query("SELECT show_data FROM podcast_private_shows WHERE viewer_did=\(viewer) AND id=\(show.id) FOR UPDATE", logger: logger)
        var existing = false
        for try await row in rows {
          _ = try storage.open(row.decode(String.self), viewer: viewer, entity: "show", id: show.id)
          existing = true
        }
        guard !existingOnly || existing else { throw PodcastStoreError.notFound }
        _ = try await connection.query("""
          INSERT INTO podcast_private_shows(viewer_did,id,feed_hash,feed_data,show_data) VALUES(\(viewer),\(show.id),\(feedHash),\(feedData),\(showData))
          ON CONFLICT(viewer_did,id) DO UPDATE SET feed_data=EXCLUDED.feed_data,show_data=EXCLUDED.show_data,updated_at=now()
          """, logger: logger)
        for entry in entries {
          _ = try await connection.query("""
            INSERT INTO podcast_private_episodes(viewer_did,id,show_id,episode_data,published_at)
            VALUES(\(viewer),\(entry.0),\(show.id),\(entry.1),\(entry.2))
            ON CONFLICT(viewer_did,id) DO UPDATE SET episode_data=EXCLUDED.episode_data,published_at=EXCLUDED.published_at
            """, logger: logger)
        }
      }
    } catch let error as PostgresTransactionError {
      if let storageError = error.closureError as? PodcastStoreError { throw storageError }
      throw error
    }
  }

  public func privateShows(viewer: String) async throws -> [PodcastShow] {
    guard let privateStorage else { return [] }
    let rows = try await pool.query("SELECT id,show_data FROM podcast_private_shows WHERE viewer_did=\(viewer) ORDER BY id", logger: logger)
    var shows: [PodcastShow] = []
    for try await row in rows {
      let value = try row.decode((String, String).self)
      shows.append(try decode(privateStorage.open(value.1, viewer: viewer, entity: "show", id: value.0), PodcastShow.self))
    }
    return shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  public func privateShow(viewer: String, id: String) async throws -> PodcastShow? {
    let storage = try requirePrivateStorage()
    let rows = try await pool.query("SELECT show_data FROM podcast_private_shows WHERE viewer_did=\(viewer) AND id=\(id)", logger: logger)
    for try await row in rows { return try decode(storage.open(row.decode(String.self), viewer: viewer, entity: "show", id: id), PodcastShow.self) }
    return nil
  }

  public func privateFeed(viewer: String, id: String) async throws -> (url: String, refreshedAt: Date)? {
    let storage = try requirePrivateStorage()
    let rows = try await pool.query("SELECT feed_data,updated_at FROM podcast_private_shows WHERE viewer_did=\(viewer) AND id=\(id)", logger: logger)
    for try await row in rows {
      let value = try row.decode((String, Date).self)
      return (try storage.open(value.0, viewer: viewer, entity: "feed", id: id), value.1)
    }
    return nil
  }

  public func privateEpisode(viewer: String, id: String) async throws -> PodcastEpisode? {
    _ = try requirePrivateStorage()
    let rows = try await pool.query("SELECT episode_data FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND id=\(id)", logger: logger)
    for try await row in rows { return try privateEpisode(row.decode(String.self), viewer: viewer, id: id) }
    return nil
  }

  public func privateEpisodes(viewer: String, showID: String, cursor: String?, limit: Int) async throws -> [PodcastEpisode] {
    _ = try requirePrivateStorage()
    let rows = try await pool.query("""
      SELECT id,episode_data FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND show_id=\(showID)
      AND (\(cursor)::text IS NULL OR (published_at,id)<(SELECT published_at,id FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND id=\(cursor)))
      ORDER BY published_at DESC,id DESC LIMIT \(max(1,min(limit,100)))
      """, logger: logger)
    var episodes: [PodcastEpisode] = []
    for try await row in rows {
      let value = try row.decode((String, String).self)
      episodes.append(try privateEpisode(value.1, viewer: viewer, id: value.0))
    }
    return episodes
  }

  public func subscribedEpisodes(viewer: String, cursor: String?, limit: Int) async throws -> [PodcastEpisode] {
    let rows = try await pool.query("""
      WITH catalog AS (
        SELECT e.id,e.published_at,e.episode_json::text AS payload,false AS is_private FROM podcast_episodes e JOIN podcast_subscriptions s ON s.show_id=e.show_id WHERE s.viewer_did=\(viewer)
        UNION ALL SELECT id,published_at,episode_data,true FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND \(privateStorage != nil)
      ) SELECT id,payload,is_private FROM catalog
      WHERE (\(cursor)::text IS NULL OR (published_at,id)<(SELECT published_at,id FROM catalog WHERE id=\(cursor)))
      ORDER BY published_at DESC,id DESC LIMIT \(max(1,min(limit,100)))
      """, logger: logger)
    var episodes: [PodcastEpisode] = []
    for try await row in rows {
      let value = try row.decode((String, String, Bool).self)
      episodes.append(try value.2 ? privateEpisode(value.1, viewer: viewer, id: value.0) : decode(value.1, PodcastEpisode.self))
    }
    return episodes
  }

  public func removePrivateSubscription(viewer: String, showID: String) async throws -> Bool {
    guard try await privateShow(viewer: viewer, id: showID) != nil else { return false }
    let rows = try await pool.query("""
      WITH ids AS MATERIALIZED (SELECT id FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND show_id=\(showID)),
      removed AS (DELETE FROM podcast_private_shows WHERE viewer_did=\(viewer) AND id=\(showID) RETURNING id),
      state AS (UPDATE podcast_viewer_state SET revision=revision+1,updated_at=now(),state_json=state_json || jsonb_build_object(
        'queue',COALESCE((SELECT jsonb_agg(value) FROM jsonb_array_elements_text(COALESCE(state_json->'queue','[]'::jsonb)) WHERE value NOT IN(SELECT id FROM ids)),'[]'::jsonb),
        'progress',COALESCE(state_json->'progress','{}'::jsonb)-ARRAY(SELECT id FROM ids),
        'subscriptions',COALESCE((SELECT jsonb_agg(value) FROM jsonb_array_elements_text(COALESCE(state_json->'subscriptions','[]'::jsonb)) WHERE value<>\(showID)),'[]'::jsonb)
      ) WHERE viewer_did=\(viewer) AND EXISTS(SELECT id FROM removed))
      SELECT id FROM removed
      """, logger: logger)
    for try await _ in rows { return true }
    return false
  }
}
