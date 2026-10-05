import Foundation
import Logging
import PostgresNIO

public actor PostgresPodcastStore {
  let pool: PostgresClient
  let logger: Logger
  let privateStorage: PodcastPrivateStorage?
  public init(pool: PostgresClient, logger: Logger, privateStorageKey: String? = ProcessInfo.processInfo.environment["PODCAST_PRIVATE_STORAGE_KEY"]) {
    self.pool = pool
    self.logger = logger
    self.privateStorage = privateStorageKey.flatMap { try? PodcastPrivateStorage(base64Key: $0) }
  }
  func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
  func decode<T: Decodable>(_ raw: String, _ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: Data(raw.utf8))
  }
  public func upsert(show: PodcastShow, episodes: [PodcastEpisode]) async throws {
    guard show.visibility != "private", !PodcastPrivateCatalog.isPrivateID(show.id),
      episodes.allSatisfy({ $0.visibility != "private" && !PodcastPrivateCatalog.isPrivateID($0.id) })
    else { throw PodcastStoreError.invalidRequest }
    let data = try json(show)
    _ = try await pool.query(
      """
      INSERT INTO podcast_shows(id,feed_url,source_kind,source_uri,show_json) VALUES (\(show.id),\(show.feedUrl),\(show.sourceKind),\(show.sourceUri),\(data)::jsonb)
      ON CONFLICT(id) DO UPDATE SET show_json=EXCLUDED.show_json, source_uri=COALESCE(EXCLUDED.source_uri,podcast_shows.source_uri), updated_at=now()
      """, logger: logger)
    for var episode in episodes {
      if let guid = episode.guid {
        let existing = try await pool.query(
          "SELECT id,episode_json::text FROM podcast_episodes WHERE show_id=\(show.id) AND guid=\(guid)",
          logger: logger)
        for try await row in existing {
          let value = try row.decode((String, String).self)
          let canonical = value.0
          let existing = try decode(value.1, PodcastEpisode.self)
          episode.sourceUri = episode.sourceUri ?? existing.sourceUri
          if episode.chapters.isEmpty, episode.chapterSourceUrl == existing.chapterSourceUrl {
            episode.chapters = existing.chapters
          }
          if canonical != episode.id {
            try await alias(episode.id, canonical: canonical, kind: "episode")
            episode.id = canonical
          }
          break
        }
      }
      let data = try json(episode)
      let date =
        ISO8601DateFormatter().date(from: episode.publishedAt) ?? Date(timeIntervalSince1970: 0)
      _ = try await pool.query(
        """
        INSERT INTO podcast_episodes(id,show_id,guid,episode_json,published_at) VALUES (\(episode.id),\(show.id),\(episode.guid),\(data)::jsonb,\(date))
        ON CONFLICT(id) DO UPDATE SET episode_json=EXCLUDED.episode_json,updated_at=now()
        """, logger: logger)
    }
    if let feed = show.feedUrl { try await alias(feed, canonical: show.id, kind: "show") }
    if let source = show.sourceUri { try await alias(source, canonical: show.id, kind: "show") }
    if let guid = show.guid { try await alias("guid:" + guid, canonical: show.id, kind: "show") }
  }
  public func alias(_ alias: String, canonical: String, kind: String) async throws {
    _ = try await pool.query(
      "INSERT INTO podcast_aliases(alias,canonical_id,entity_kind) VALUES(\(alias),\(canonical),\(kind)) ON CONFLICT(alias) DO NOTHING",
      logger: logger)
  }
  public func show(id: String) async throws -> PodcastShow? {
    let rows = try await pool.query(
      "SELECT show_json::text FROM podcast_shows WHERE id=\(id) OR id=(SELECT canonical_id FROM podcast_aliases WHERE alias=\(id) AND entity_kind='show') LIMIT 1",
      logger: logger)
    for try await row in rows { return try decode(row.decode(String.self), PodcastShow.self) }
    return nil
  }
  public func shows(viewer: String) async throws -> [PodcastShow] {
    let rows = try await pool.query(
      "SELECT s.show_json::text FROM podcast_shows s JOIN podcast_subscriptions v ON v.show_id=s.id WHERE v.viewer_did=\(viewer) ORDER BY lower(s.show_json->>'title'),s.id",
      logger: logger)
    var shows: [PodcastShow] = []
    for try await row in rows {
      shows.append(try decode(row.decode(String.self), PodcastShow.self))
    }
    return shows
  }
  public func episode(id: String) async throws -> PodcastEpisode? {
    let rows = try await pool.query(
      "SELECT episode_json::text FROM podcast_episodes WHERE id=\(id) OR id=(SELECT canonical_id FROM podcast_aliases WHERE alias=\(id) AND entity_kind='episode') LIMIT 1",
      logger: logger)
    for try await row in rows { return try decode(row.decode(String.self), PodcastEpisode.self) }
    return nil
  }
  public func episodes(showID: String, cursor: String?, limit: Int) async throws -> [PodcastEpisode]
  {
    let rows = try await pool.query(
      """
      SELECT episode_json::text FROM podcast_episodes WHERE show_id=\(showID)
      AND (\(cursor)::text IS NULL OR (published_at,id)<(SELECT published_at,id FROM podcast_episodes WHERE id=\(cursor)))
      ORDER BY published_at DESC,id DESC LIMIT \(max(1,min(limit,100)))
      """, logger: logger)
    var result: [PodcastEpisode] = []
    for try await row in rows {
      result.append(try decode(row.decode(String.self), PodcastEpisode.self))
    }
    return result
  }
  public func canonicalEpisodeIDs(_ ids: [String]) async throws -> [String: String] {
    guard !ids.isEmpty else { return [:] }
    let rows = try await pool.query(
      "SELECT alias,canonical_id FROM podcast_aliases WHERE alias=ANY(\(ids)) AND entity_kind='episode'",
      logger: logger)
    var aliases: [String: String] = [:]
    for try await row in rows {
      let value = try row.decode((String, String).self)
      aliases[value.0] = value.1
    }
    return aliases
  }
  public func manualEpisodeAliases(links: [PodcastManualLink]) async throws -> [String: String] {
    var aliases: [String: String] = [:]
    for link in links {
      let rows = try await pool.query(
        "SELECT native.id,rss.id FROM podcast_episodes native JOIN podcast_episodes rss ON rss.guid=native.guid WHERE native.show_id=\(link.protocolShowId) AND rss.show_id=\(link.rssShowId) AND native.guid IS NOT NULL",
        logger: logger)
      for try await row in rows {
        let ids = try row.decode((String, String).self)
        aliases[ids.0] = ids.1
      }
    }
    return aliases
  }
  public func subscriptions(viewer: String, records: [(showID: String, uri: String)]) async throws {
    let ids = records.map(\.showID)
    _ = try await pool.query(
      "DELETE FROM podcast_subscriptions WHERE viewer_did=\(viewer) AND NOT(show_id=ANY(\(ids)))",
      logger: logger)
    for record in records {
      _ = try await pool.query(
        "INSERT INTO podcast_subscriptions(viewer_did,show_id,source_uri) VALUES(\(viewer),\(record.showID),\(record.uri)) ON CONFLICT(viewer_did,show_id) DO UPDATE SET source_uri=EXCLUDED.source_uri,updated_at=now()",
        logger: logger)
    }
  }
  public func state(viewer: String) async throws -> PodcastStateSnapshot {
    let rows = try await pool.query(
      "SELECT revision,state_json::text FROM podcast_viewer_state WHERE viewer_did=\(viewer)",
      logger: logger)
    for try await row in rows {
      let value = try row.decode((Int64, String).self)
      var state = try decode(value.1, PodcastListenerState.self)
      state.normalizePlaybackSpeed()
      return PodcastStateSnapshot(revision: value.0, state: state)
    }
    return PodcastStateSnapshot(revision: 0, state: PodcastListenerState())
  }
  public func saveState(viewer: String, expected: Int64, state: PodcastListenerState) async throws
    -> PodcastStateSnapshot
  {
    guard expected >= 0, state.validate() else { throw PodcastStoreError.invalidState }
    let privateIDs = Set(state.queue + Array(state.progress.keys)).filter(PodcastPrivateCatalog.isPrivateID)
    guard try await ownsPrivateEpisodes(viewer: viewer, ids: Array(privateIDs)) else { throw PodcastStoreError.invalidState }
    let data = try json(state)
    let rows = try await pool.query(
      """
      INSERT INTO podcast_viewer_state(viewer_did,revision,state_json)
      SELECT \(viewer),1,\(data)::jsonb WHERE \(expected)=0
      ON CONFLICT(viewer_did) DO UPDATE SET revision=podcast_viewer_state.revision+1,state_json=EXCLUDED.state_json,updated_at=now()
      WHERE podcast_viewer_state.revision=\(expected)
      RETURNING revision
      """, logger: logger)
    for try await row in rows {
      return PodcastStateSnapshot(revision: try row.decode(Int64.self), state: state)
    }
    // Nonzero revisions cannot INSERT, so update them separately.
    if expected > 0 {
      let updated = try await pool.query(
        "UPDATE podcast_viewer_state SET revision=revision+1,state_json=\(data)::jsonb,updated_at=now() WHERE viewer_did=\(viewer) AND revision=\(expected) RETURNING revision",
        logger: logger)
      for try await row in updated {
        return PodcastStateSnapshot(revision: try row.decode(Int64.self), state: state)
      }
    }
    throw PodcastStoreError.revisionConflict
  }
  public func enqueue(
    viewer: String?, episodeID: String?, kind: String, key: String, payload: String
  ) async throws -> String {
    if let episodeID, PodcastPrivateCatalog.isPrivateID(episodeID) { throw PodcastStoreError.invalidRequest }
    let id = UUID()
    let rows = try await pool.query(
      """
      INSERT INTO podcast_jobs(id,viewer_did,episode_id,kind,dedupe_key,payload_json) VALUES(\(id),\(viewer),\(episodeID),\(kind),\(key),\(payload)::jsonb)
      ON CONFLICT(dedupe_key) DO UPDATE SET dedupe_key=EXCLUDED.dedupe_key RETURNING id::text
      """, logger: logger)
    for try await row in rows { return try row.decode(String.self) }
    throw PodcastStoreError.notFound
  }
  public func job(
    viewer: String, jobID: String?, episodeID: String?, kind: String?, showID: String? = nil,
    key: String? = nil, clipID: String? = nil
  ) async throws -> String? {
    let rows = try await pool.query(
      """
      SELECT jsonb_build_object('id',id::text,'kind',kind,'status',status,'result',result_json,'error',error)::text FROM podcast_jobs
      WHERE (viewer_did=\(viewer) OR (viewer_did IS NULL AND kind='silence') OR (viewer_did IS NULL AND kind='bridge' AND EXISTS(SELECT 1 FROM podcast_subscriptions s WHERE s.viewer_did=\(viewer) AND s.show_id=podcast_jobs.payload_json->>'showId')))
      AND (\(jobID)::text IS NULL OR id::text=\(jobID)) AND (\(episodeID)::text IS NULL OR episode_id=\(episodeID)) AND (\(kind)::text IS NULL OR kind=\(kind)) AND (\(showID)::text IS NULL OR payload_json->>'showId'=\(showID)) AND (\(key)::text IS NULL OR dedupe_key=\(key)) AND (\(clipID)::text IS NULL OR payload_json->>'clipId'=\(clipID)) ORDER BY created_at DESC LIMIT 1
      """, logger: logger)
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }
  public func invalidateAnalysis(id: String, fingerprint: String) async throws {
    _ = try await pool.query(
      "UPDATE podcast_jobs SET status='failed',result_json=NULL,error='Media Source Changed During Analysis',updated_at=now() WHERE id::text=\(id) AND kind='silence' AND status='complete' AND result_json->>'sourceFingerprint' IS DISTINCT FROM \(fingerprint)",
      logger: logger)
  }
  public func retry(viewer: String, id: String) async throws -> Bool {
    guard try await job(viewer: viewer, jobID: id, episodeID: nil, kind: nil) != nil else {
      return false
    }
    let rows = try await pool.query(
      """
      WITH retried AS (
        UPDATE podcast_jobs SET status='queued',available_at=now(),error=NULL,updated_at=now()
        WHERE id::text=\(id) AND status='failed' AND attempts<5 AND kind IN ('bridge','silence','clip')
        RETURNING id,kind,payload_json
      ), reset_clip AS (
        UPDATE podcast_clips SET clip_json=jsonb_set(clip_json-'error','{status}','"queued"'::jsonb),updated_at=now()
        FROM retried WHERE retried.kind='clip' AND podcast_clips.id::text=retried.payload_json->>'clipId'
        RETURNING podcast_clips.id
      ) SELECT id::text FROM retried
      """,
      logger: logger)
    for try await _ in rows { return true }
    return false
  }
  public func prepareClip(viewer: String, clip: PodcastClip, payload: String) async throws -> String
  {
    guard let clipID = UUID(uuidString: clip.id), !PodcastPrivateCatalog.isPrivateID(clip.episodeId)
    else { throw PodcastStoreError.invalidRequest }
    let jobID = UUID()
    let data = try json(clip)
    let key = "clip:" + clip.id
    let rows = try await pool.query(
      """
      WITH draft AS (
        INSERT INTO podcast_clips(id,viewer_did,episode_id,clip_json) VALUES(\(clipID),\(viewer),\(clip.episodeId),\(data)::jsonb) RETURNING id
      ) INSERT INTO podcast_jobs(id,viewer_did,episode_id,kind,dedupe_key,payload_json)
      SELECT \(jobID),\(viewer),\(clip.episodeId),'clip',\(key),\(payload)::jsonb FROM draft RETURNING id::text
      """, logger: logger)
    for try await row in rows { return try row.decode(String.self) }
    throw PodcastStoreError.notFound
  }
  public func removeClip(viewer: String, clip: PodcastClip, payload: String) async throws {
    let jobID = UUID()
    let key = "cleanup:" + clip.id
    _ = try await pool.query(
      """
      WITH removed AS (
        DELETE FROM podcast_clips WHERE id::text=\(clip.id) AND viewer_did=\(viewer) RETURNING id
      ) INSERT INTO podcast_jobs(id,viewer_did,episode_id,kind,dedupe_key,payload_json)
      SELECT \(jobID),\(viewer),\(clip.episodeId),'cleanup',\(key),\(payload)::jsonb FROM removed ON CONFLICT(dedupe_key) DO NOTHING
      """, logger: logger)
  }
  public func createClip(viewer: String, clip: PodcastClip) async throws {
    guard let id = UUID(uuidString: clip.id) else { throw PodcastStoreError.invalidRequest }
    let data = try json(clip)
    _ = try await pool.query(
      "INSERT INTO podcast_clips(id,viewer_did,episode_id,clip_json) VALUES(\(id),\(viewer),\(clip.episodeId),\(data)::jsonb)",
      logger: logger)
  }
  public func clips(viewer: String) async throws -> [PodcastClip] {
    let rows = try await pool.query(
      "SELECT (clip_json || jsonb_build_object('jobId',(SELECT id::text FROM podcast_jobs WHERE podcast_jobs.payload_json->>'clipId'=podcast_clips.id::text AND kind='clip' ORDER BY created_at DESC LIMIT 1)))::text FROM podcast_clips WHERE viewer_did=\(viewer) ORDER BY updated_at DESC LIMIT 100",
      logger: logger)
    var clips: [PodcastClip] = []
    for try await row in rows {
      clips.append(try decode(row.decode(String.self), PodcastClip.self))
    }
    return clips
  }
  public func clip(id: String, viewer: String?, publishedOnly: Bool = false) async throws
    -> PodcastClip?
  {
    let rows = try await pool.query(
      "SELECT clip_json::text FROM podcast_clips WHERE (id::text=\(id) OR published_uri=\(id)) AND (\(viewer)::text IS NULL OR viewer_did=\(viewer)) AND (NOT \(publishedOnly) OR published_uri IS NOT NULL) LIMIT 1",
      logger: logger)
    for try await row in rows { return try decode(row.decode(String.self), PodcastClip.self) }
    return nil
  }
  public func publishClip(id: String, viewer: String, uri: String) async throws {
    _ = try await pool.query(
      "UPDATE podcast_clips SET published_uri=\(uri),clip_json=jsonb_set(clip_json,'{publishedUri}',to_jsonb(\(uri)::text)),updated_at=now() WHERE id::text=\(id) AND viewer_did=\(viewer)",
      logger: logger)
  }
  public func deleteClip(id: String, viewer: String) async throws {
    _ = try await pool.query(
      "DELETE FROM podcast_clips WHERE id::text=\(id) AND viewer_did=\(viewer)", logger: logger)
  }
}
