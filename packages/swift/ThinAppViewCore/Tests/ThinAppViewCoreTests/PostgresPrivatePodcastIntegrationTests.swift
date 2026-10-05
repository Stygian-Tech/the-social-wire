import Foundation
import Logging
import PostgresNIO
import Testing

@testable import ThinAppViewCore

struct PostgresPrivatePodcastIntegrationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PODCAST_PRIVATE_TEST_DATABASE_URL"] != nil))
  func privateCatalogIsolationAndUnsubscribeCleanup() async throws {
    guard let url = ProcessInfo.processInfo.environment["PODCAST_PRIVATE_TEST_DATABASE_URL"],
      let host = URL(string: url)?.host, ["127.0.0.1", "localhost", "::1"].contains(host)
    else { return }
    var logger = Logger(label: "private-podcast-integration")
    logger.logLevel = .critical
    let pool = PostgresClient(configuration: try makePostgresConfig(from: url, logger: logger), backgroundLogger: logger)
    let run = Task { await pool.run() }
    defer { run.cancel() }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    for name in ["20261005010000_podcast_listener.sql", "20261006010000_private_podcast_subscriptions.sql"] {
      let migration = try String(contentsOf: root.appendingPathComponent("database/migrations/" + name), encoding: .utf8)
      let statements = migration.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n").components(separatedBy: ";")
      for statement in statements where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = try await pool.query(PostgresQuery(unsafeSQL: statement), logger: logger)
      }
    }
    let key = Data(repeating: 7, count: 32).base64EncodedString()
    let store = PostgresPodcastStore(pool: pool, logger: logger, privateStorageKey: key)
    let suffix = UUID().uuidString
    let owner = "did:plc:private-owner-" + suffix
    let other = "did:plc:private-other-" + suffix
    let feed = "https://feeds.example.com/private/" + suffix + "?token=owner-secret"
    let show = PodcastShow(id: "parsed-show", title: "Private", feedUrl: feed, sourceKind: "rss", guid: "shared-guid")
    let episode = PodcastEpisode(id: "parsed-episode", showId: show.id, title: "Private Episode", publishedAt: "2026-10-05T00:00:00Z", audioUrl: "https://media.example.com/a.mp3?token=owner-secret", guid: "shared-item-guid", transcripts: [])
    let scoped = PodcastPrivateCatalog.scope(viewer: owner, feedURL: feed, show: show, episodes: [episode])
    let scopedOther = PodcastPrivateCatalog.scope(viewer: other, feedURL: feed, show: show, episodes: [episode])
    try await store.savePrivateCatalog(viewer: owner, feedURL: feed, show: scoped.show, episodes: scoped.episodes)
    try await store.savePrivateCatalog(viewer: other, feedURL: feed, show: scopedOther.show, episodes: scopedOther.episodes)
    let stored = try await pool.query("SELECT row_to_json(s)::text FROM podcast_private_shows s WHERE viewer_did=\(owner)", logger: logger)
    for try await row in stored {
      let raw = try row.decode(String.self)
      #expect(!raw.contains("owner-secret"))
      #expect(!raw.contains("feeds.example.com"))
      #expect(!raw.contains("Private"))
      #expect(raw.contains("v1."))
    }
    let encryptedEpisodes = try await pool.query("SELECT episode_data FROM podcast_private_episodes WHERE viewer_did=\(owner)", logger: logger)
    for try await row in encryptedEpisodes { #expect(try !row.decode(String.self).contains("owner-secret")) }
    let wrongKey = PostgresPodcastStore(pool: pool, logger: logger, privateStorageKey: Data(repeating: 8, count: 32).base64EncodedString())
    await #expect(throws: PodcastStoreError.privateStorageUnavailable) { try await wrongKey.privateEpisode(viewer: owner, id: scoped.episodes[0].id) }
    let unavailable = PostgresPodcastStore(pool: pool, logger: logger, privateStorageKey: nil)
    #expect(try await unavailable.privateShows(viewer: owner).isEmpty)
    #expect(try await unavailable.shows(viewer: owner).isEmpty)
    await #expect(throws: PodcastStoreError.privateStorageUnavailable) { try await unavailable.savePrivateCatalog(viewer: owner, feedURL: feed, show: scoped.show, episodes: scoped.episodes) }
    #expect(try await store.privateShow(viewer: other, id: scoped.show.id) == nil)
    #expect(try await store.privateEpisode(viewer: other, id: scoped.episodes[0].id) == nil)
    #expect(try await store.privateFeed(viewer: other, id: scoped.show.id) == nil)
    #expect(try await store.privateEpisode(viewer: owner, id: scoped.episodes[0].id)?.audioUrl == episode.audioUrl)
    #expect(try await store.show(id: feed) == nil)
    #expect(try await store.show(id: scoped.show.id) == nil)
    #expect(try await store.episode(id: scoped.episodes[0].id) == nil)
    #expect(try await store.shows(viewer: owner).isEmpty)
    #expect(try await store.subscribedEpisodes(viewer: owner, cursor: nil, limit: 1).first?.id == scoped.episodes[0].id)
    #expect(try await store.subscribedEpisodes(viewer: owner, cursor: scoped.episodes[0].id, limit: 1).isEmpty)
    #expect(try await store.subscribedEpisodes(viewer: other, cursor: nil, limit: 1).first?.id == scopedOther.episodes[0].id)
    do { try await store.upsert(show: scoped.show, episodes: scoped.episodes); Issue.record("Private catalog entered public store") } catch PodcastStoreError.invalidRequest {}
    do { _ = try await store.enqueue(viewer: nil, episodeID: scoped.episodes[0].id, kind: "silence", key: scoped.episodes[0].id, payload: "{}"); Issue.record("Private episode entered public jobs") } catch PodcastStoreError.invalidRequest {}
    let clip = PodcastClip(id: UUID().uuidString, episodeId: scoped.episodes[0].id, startSeconds: 0, endSeconds: 1, title: "Private", createdAt: "2026-10-05T00:00:00Z")
    do { _ = try await store.prepareClip(viewer: owner, clip: clip, payload: "{}"); Issue.record("Private episode entered clip pipeline") } catch PodcastStoreError.invalidRequest {}
    var state = PodcastListenerState()
    state.subscriptions = [scoped.show.id]
    state.queue = [scoped.episodes[0].id]
    state.progress[scoped.episodes[0].id] = PodcastProgress(positionSeconds: 12, updatedAt: "2026-10-05T00:00:00Z")
    let saved = try await store.saveState(viewer: owner, expected: 0, state: state)
    #expect(saved.state.queue == state.queue)
    #expect(try await store.queuedEpisodes(viewer: owner).first?.id == scoped.episodes[0].id)
    #expect(try await store.queuedEpisodes(viewer: other).isEmpty)
    do { _ = try await store.saveState(viewer: other, expected: 0, state: state); Issue.record("Foreign private queue accepted") } catch PodcastStoreError.invalidState {}
    #expect(try await !store.removePrivateSubscription(viewer: other, showID: scoped.show.id))
    #expect(try await store.removePrivateSubscription(viewer: owner, showID: scoped.show.id))
    #expect(try await store.privateEpisodes(viewer: owner, showID: scoped.show.id, cursor: nil, limit: 50).isEmpty)
    let removed = try await store.state(viewer: owner)
    #expect(removed.revision == saved.revision + 1)
    #expect(removed.state.queue.isEmpty)
    #expect(removed.state.progress.isEmpty)
    #expect(removed.state.subscriptions.isEmpty)
    await #expect(throws: PodcastStoreError.notFound) {
      try await store.savePrivateCatalog(viewer: owner, feedURL: feed, show: scoped.show, episodes: scoped.episodes, existingOnly: true)
    }
    #expect(try await store.privateShow(viewer: owner, id: scoped.show.id) == nil)
    #expect(try await store.privateShows(viewer: other).count == 1)
    _ = try await store.removePrivateSubscription(viewer: other, showID: scopedOther.show.id)
    _ = try await pool.query("DELETE FROM podcast_viewer_state WHERE viewer_did=\(owner) OR viewer_did=\(other)", logger: logger)
  }
}
