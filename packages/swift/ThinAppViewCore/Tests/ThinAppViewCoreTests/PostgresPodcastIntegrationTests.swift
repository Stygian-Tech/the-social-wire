import Foundation
import Logging
import PostgresNIO
import Testing

@testable import ThinAppViewCore

struct PostgresPodcastIntegrationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PODCAST_TEST_DATABASE_URL"] != nil))
  func durableCatalogCASAndPrivateClips() async throws {
    do {
      guard let url = ProcessInfo.processInfo.environment["PODCAST_TEST_DATABASE_URL"] else {
        return
      }
      let logger = Logger(label: "podcast-integration")
      let pool = PostgresClient(
        configuration: try makePostgresConfig(from: url, logger: logger), backgroundLogger: logger)
      let run = Task { await pool.run() }
      defer { run.cancel() }
      guard let host = URL(string: url)?.host, ["127.0.0.1", "localhost", "::1"].contains(host)
      else {
        throw PodcastStoreError.invalidRequest
      }
      var root = URL(fileURLWithPath: #filePath)
      for _ in 0..<6 { root.deleteLastPathComponent() }
      let migration = try String(
        contentsOf: root.appendingPathComponent(
          "database/migrations/20261005010000_podcast_listener.sql"), encoding: .utf8)
      let statements = migration.components(separatedBy: "\n").filter {
        !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--")
      }.joined(separator: "\n").components(separatedBy: ";")
      for statement in statements
      where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = try await pool.query(PostgresQuery(unsafeSQL: statement), logger: logger)
      }
      let store = PostgresPodcastStore(pool: pool, logger: logger)
      let suffix = UUID().uuidString.lowercased()
      let viewer = "did:plc:test-" + suffix
      let other = "did:plc:other-" + suffix
      let show = PodcastShow(
        id: "show:" + suffix, title: "Show", feedUrl: "https://example.com/" + suffix,
        sourceKind: "rss")
      let episode = PodcastEpisode(
        id: "episode:" + suffix, showId: show.id, title: "Episode",
        publishedAt: "2026-10-05T00:00:00Z", audioUrl: "https://example.com/a.mp3", guid: "guid",
        transcripts: [])
      try await store.upsert(show: show, episodes: [episode])
      var duplicate = episode
      duplicate.id = "at://did:plc:publisher/org.atpodcasting.episode/" + suffix
      duplicate.sourceUri = duplicate.id
      try await store.upsert(show: show, episodes: [duplicate])
      #expect(try await store.episode(id: duplicate.id)?.id == episode.id)
      #expect(try await store.canonicalEpisodeIDs([duplicate.id])[duplicate.id] == episode.id)
      try await store.upsert(show: show, episodes: [episode])
      #expect(try await store.episode(id: episode.id)?.sourceUri == duplicate.sourceUri)
      try await store.subscriptions(
        viewer: viewer,
        records: [(show.id, "at://" + viewer + "/app.skyreader.feed.subscription/sub")])
      #expect(try await store.shows(viewer: viewer).count == 1)
      #expect(try await store.shows(viewer: other).isEmpty)
      var state = PodcastListenerState()
      state.progress[episode.id] = PodcastProgress(
        positionSeconds: 20, updatedAt: "2026-10-05T00:00:00Z")
      let one = try await store.saveState(viewer: viewer, expected: 0, state: state)
      #expect(one.revision == 1)
      do {
        _ = try await store.saveState(viewer: viewer, expected: 0, state: state)
        Issue.record("Stale revision accepted")
      } catch PodcastStoreError.revisionConflict {}
      state.progress[episode.id]?.positionSeconds = 5
      let two = try await store.saveState(viewer: viewer, expected: 1, state: state)
      #expect(two.revision == 2)
      #expect(two.state.progress[episode.id]?.positionSeconds == 5)
      let clip = PodcastClip(
        id: UUID().uuidString.lowercased(), episodeId: episode.id, startSeconds: 1, endSeconds: 10,
        title: "Clip", createdAt: "2026-10-05T00:00:00Z")
      let payload = "{\"clipId\":\"" + clip.id + "\"}"
      let job = try await store.prepareClip(viewer: viewer, clip: clip, payload: payload)
      #expect(try await store.clip(id: clip.id, viewer: other) == nil)
      #expect(try await store.clip(id: clip.id, viewer: nil, publishedOnly: true) == nil)
      _ = try await pool.query(
        "UPDATE podcast_jobs SET status='failed',attempts=4 WHERE id::text=\(job)", logger: logger)
      _ = try await pool.query(
        "UPDATE podcast_clips SET clip_json=jsonb_set(clip_json,'{status}','\"failed\"'::jsonb) WHERE id::text=\(clip.id)",
        logger: logger)
      _ = try await store.enqueue(
        viewer: viewer, episodeID: episode.id, kind: "clip", key: "clip:" + clip.id,
        payload: payload)
      #expect(
        try await store.job(viewer: viewer, jobID: job, episodeID: nil, kind: nil)?.contains(
          "failed") == true)
      #expect(try await store.retry(viewer: viewer, id: job))
      #expect(try await store.clips(viewer: viewer).first?.status == "queued")
      #expect(try await store.clips(viewer: viewer).first?.jobId == job)
      #expect(
        try await store.job(
          viewer: viewer, jobID: nil, episodeID: nil, kind: "clip", clipID: clip.id) != nil)
      _ = try await pool.query(
        "UPDATE podcast_jobs SET status='failed',attempts=5 WHERE id::text=\(job)", logger: logger)
      #expect(try await !store.retry(viewer: viewer, id: job))
      #expect(try await store.job(viewer: other, jobID: job, episodeID: nil, kind: nil) == nil)
      #expect(try await store.job(viewer: viewer, jobID: job, episodeID: nil, kind: nil) != nil)
      try await store.subscriptions(viewer: viewer, records: [])
      #expect(try await store.shows(viewer: viewer).isEmpty)
      try await store.removeClip(viewer: viewer, clip: clip, payload: payload)
      #expect(try await store.clip(id: clip.id, viewer: viewer) == nil)
      #expect(
        try await store.job(viewer: viewer, jobID: nil, episodeID: episode.id, kind: "cleanup")
          != nil)
      _ = try await pool.query(
        "DELETE FROM podcast_jobs WHERE viewer_did=\(viewer)", logger: logger)
      _ = try await pool.query(
        "DELETE FROM podcast_viewer_state WHERE viewer_did=\(viewer)", logger: logger)
      _ = try await pool.query(
        "DELETE FROM podcast_episodes WHERE show_id=\(show.id)", logger: logger)
      _ = try await pool.query(
        "DELETE FROM podcast_aliases WHERE canonical_id=\(show.id) OR canonical_id=\(episode.id)", logger: logger)
      _ = try await pool.query("DELETE FROM podcast_shows WHERE id=\(show.id)", logger: logger)
    } catch let error as PSQLError {
      Issue.record(
        "PostgreSQL integration diagnostic: \(error.serverInfo?[.message] ?? String(describing:error.code))"
      )
      throw error
    }
  }
}
