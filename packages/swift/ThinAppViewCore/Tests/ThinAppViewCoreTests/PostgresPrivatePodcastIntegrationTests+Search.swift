import Foundation
import Logging
import PostgresNIO
import Testing
@testable import ThinAppViewCore

extension PostgresPrivatePodcastIntegrationTests {
  func searchIsolation(pool: PostgresClient, store: PostgresPodcastStore, logger: Logger, owner: String, other: String, suffix: String, privateShowID: String) async throws {
    var show = PodcastShow(id: "search-show-" + suffix, title: "Public Café Search", sourceKind: "rss")
    show.hosts = [PodcastPerson(name: "Example Host")]
    let episodes = (0..<505).map { index in
      PodcastEpisode(id: "search-episode-" + suffix + String(format: "-%04d", index), showId: show.id,
        title: index == 504 ? "Late Search Needle" : "Ordinary Episode", publishedAt: "2026-10-05T00:00:00Z",
        audioUrl: "https://example.com/audio.mp3", transcripts: [])
    }
    try await store.upsert(show: show, episodes: episodes)
    try await store.subscriptions(viewer: owner, records: [(show.id, "at://" + owner + "/app.skyreader.feed.subscription/search")])
    let publicHits = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "cafe host", kind: "shows"))
    #expect(publicHits.shows.map(\.id) == [show.id])
    #expect(!publicHits.hasMore && publicHits.cursor == nil)
    let publicOnly = PostgresPodcastStore(pool: pool, logger: logger, privateStorageKey: nil)
    #expect(try await publicOnly.search(viewer: owner, request: PodcastSearchRequest(query: "cafe", kind: "shows")).shows.map(\.id) == [show.id])
    let wrongKey = PostgresPodcastStore(pool: pool, logger: logger, privateStorageKey: Data(repeating: 9, count: 32).base64EncodedString())
    await #expect(throws: PodcastStoreError.privateStorageUnavailable) {
      try await wrongKey.search(viewer: owner, request: PodcastSearchRequest(query: "private", kind: "shows"))
    }
    let foreign = try await store.search(viewer: other, request: PodcastSearchRequest(query: "cafe", kind: "all"))
    #expect(foreign.shows.isEmpty && foreign.episodes.isEmpty)
    let privateHits = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "private"))
    #expect(privateHits.shows.map(\.id) == [privateShowID])
    #expect(privateHits.shows.first?.feedUrl == nil)
    #expect(privateHits.episodes.first?.audioUrl.hasPrefix("/v1/podcasts/media?") == true)
    #expect(!String(decoding: try JSONEncoder().encode(privateHits), as: UTF8.self).contains("owner-secret"))
    let foreignScope = try await store.search(viewer: other, request: PodcastSearchRequest(query: "private", showId: privateShowID))
    #expect(foreignScope.shows.isEmpty && foreignScope.episodes.isEmpty)
    let secretSearch = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "owner-secret", showId: privateShowID))
    #expect(secretSearch.shows.isEmpty && secretSearch.episodes.isEmpty)
    let first = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "late needle", kind: "episodes"))
    #expect(first.episodes.isEmpty && first.hasMore)
    let cursor = try #require(first.cursor)
    let second = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "late needle", kind: "episodes", cursor: cursor))
    #expect(second.episodes.map(\.id) == [episodes[504].id])
    #expect(!second.hasMore)
    await #expect(throws: PodcastStoreError.invalidRequest) {
      try await store.search(viewer: other, request: PodcastSearchRequest(query: "late needle", kind: "episodes", cursor: cursor))
    }
    var seen: [String] = []
    var continuation: String?
    repeat {
      let page = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "ordinary", kind: "episodes", showId: show.id, limit: 100, cursor: continuation))
      seen += page.episodes.map(\.id)
      continuation = page.cursor
    } while continuation != nil
    #expect(seen.count == 504 && Set(seen).count == 504)
    let nativeShow = PodcastShow(id: "search-native-" + suffix, title: "Linked Needle Show", sourceKind: "atproto")
    let rssEpisode = PodcastEpisode(id: "search-rss-linked-" + suffix, showId: show.id, title: "Linked Needle Episode", publishedAt: "2026-10-05T00:00:00Z", audioUrl: "https://example.com/rss.mp3", guid: "linked-guid", transcripts: [])
    let nativeDuplicate = PodcastEpisode(id: "search-native-duplicate-" + suffix, showId: nativeShow.id, title: "Linked Needle Episode", publishedAt: "2026-10-05T00:00:00Z", audioUrl: "https://example.com/native.mp3", guid: "linked-guid", transcripts: [])
    let nativeUnique = PodcastEpisode(id: "search-native-unique-" + suffix, showId: nativeShow.id, title: "Linked Needle Bonus", publishedAt: "2026-10-05T00:00:00Z", audioUrl: "https://example.com/bonus.mp3", guid: "bonus-guid", transcripts: [])
    try await store.upsert(show: show, episodes: [rssEpisode])
    try await store.upsert(show: nativeShow, episodes: [nativeDuplicate, nativeUnique])
    try await store.subscriptions(viewer: owner, records: [(show.id, "at://" + owner + "/subscription/rss"), (nativeShow.id, "at://" + owner + "/subscription/native")])
    var linkedState = PodcastListenerState()
    linkedState.manualLinks = [PodcastManualLink(rssShowId: show.id, protocolShowId: nativeShow.id)]
    _ = try await store.saveState(viewer: owner, expected: 0, state: linkedState)
    let linkedShows = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "linked needle", kind: "shows"))
    #expect(linkedShows.shows.isEmpty)
    var linkedEpisodes: [PodcastEpisode] = []
    var linkedCursor: String?
    repeat {
      let page = try await store.search(viewer: owner, request: PodcastSearchRequest(query: "linked needle", kind: "episodes", showId: show.id, limit: 1, cursor: linkedCursor))
      linkedEpisodes += page.episodes
      linkedCursor = page.cursor
    } while linkedCursor != nil
    #expect(Set(linkedEpisodes.map(\.id)) == Set([rssEpisode.id, nativeUnique.id]))
    #expect(linkedEpisodes.count == 2 && linkedEpisodes.allSatisfy { $0.showId == show.id })
    _ = try await pool.query("DELETE FROM podcast_viewer_state WHERE viewer_did=\(owner)", logger: logger)
    _ = try await pool.query("DELETE FROM podcast_subscriptions WHERE show_id=\(nativeShow.id)", logger: logger)
    _ = try await pool.query("DELETE FROM podcast_episodes WHERE show_id=\(nativeShow.id)", logger: logger)
    _ = try await pool.query("DELETE FROM podcast_shows WHERE id=\(nativeShow.id)", logger: logger)
    _ = try await pool.query("DELETE FROM podcast_subscriptions WHERE show_id=\(show.id)", logger: logger)
    _ = try await pool.query("DELETE FROM podcast_episodes WHERE show_id=\(show.id)", logger: logger)
    _ = try await pool.query("DELETE FROM podcast_shows WHERE id=\(show.id)", logger: logger)
  }
}
