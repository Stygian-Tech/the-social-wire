import Foundation
import Testing
@testable import SocialWire

@Suite("Podcast listener contracts")
struct PodcastListenerTests {
    @Test("Playback speed preserves the supported quarter-step range")
    func playbackSpeedBounds() {
        #expect(PodcastPlaybackController.normalizedSpeed(0) == 0.75)
        #expect(PodcastPlaybackController.normalizedSpeed(5) == 2)
        #expect(PodcastPlaybackController.normalizedSpeed(.nan) == 1)
        #expect(PodcastPlaybackController.normalizedSpeed(1.26) == 1.25)
    }

    @Test("Gateway episodes retain source media and timed transcript references")
    func episodeDecoding() throws {
        let data = Data(#"{"id":"ep1","showId":"show1","title":"An Episode","publishedAt":"2026-10-04T00:00:00Z","audioUrl":"https://example.com/source.mp3","durationSeconds":3600,"transcripts":[{"url":"https://example.com/captions.vtt","type":"text/vtt"}]}"#.utf8)
        let episode = try JSONDecoder().decode(PodcastEpisode.self, from: data)
        #expect(episode.audioURL == "https://example.com/source.mp3")
        #expect(episode.durationSeconds == 3600)
        #expect(episode.transcripts.first?.type == "text/vtt")
        #expect(episode.chapters == nil)
    }

    @Test("Server privacy controls public processing while signed public CDN media remains supported")
    func privateMediaBoundaries() throws {
        func episode(_ audio: String, visibility: String? = nil) throws -> PodcastEpisode {
            var object: [String: Any] = ["id": "private-episode", "showId": "private-show", "title": "Private Episode", "publishedAt": "2026-10-04T00:00:00Z", "audioUrl": audio, "transcripts": []]
            if let visibility { object["visibility"] = visibility }
            return try JSONDecoder().decode(PodcastEpisode.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try episode("https://example.com/audio.mp3").permitsPublicProcessing)
        #expect(try !episode("https://example.com/audio.mp3", visibility: "private").permitsPublicProcessing)
        #expect(try episode("/v1/podcasts/media?episodeId=private-episode").isPrivate)
        #expect(try episode("https://example.com/audio.mp3?access_token=cdn-token&signature=cdn-signature").permitsPublicProcessing)
        #expect(try !episode("https://example.com/audio.mp3?signature=cdn-signature", visibility: "private").permitsPublicProcessing)
        #expect(try !episode("https://api.example.com/v1/podcasts/media?episodeId=private-episode").permitsPublicProcessing)
        #expect(!PodcastPrivacy.permitsPublicURL("https://example.com/feed.xml?access_token=subscriber-token"))
        #expect(try !episode("https://user:secret@example.com/audio.mp3").permitsPublicProcessing)
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"private-show","title":"Private Show","sourceKind":"private-rss","visibility":"private"}"#.utf8))
        #expect(show.isPrivate)
        #expect(show.feedUrl == nil)
        #expect(show.sourceUri == nil)
    }

    @Test("Downloaded private episode metadata remains offline and isolated by viewer")
    @MainActor
    func privateDownloadRestoration() throws {
        let viewer = "did:plc:private-download-test-\(UUID().uuidString)"
        let otherViewer = "did:plc:other-download-test-\(UUID().uuidString)"
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PodcastDownloads")
        let directory = root.appendingPathComponent(PodcastDownloadStore.key(viewer))
        let indexKey = "podcast-download-index.\(PodcastDownloadStore.key(viewer))"
        let episode = try JSONDecoder().decode(PodcastEpisode.self, from: Data(#"{"id":"private-episode","showId":"private-show","title":"Private/Show: Episode","publishedAt":"2026-10-04T00:00:00Z","audioUrl":"/v1/podcasts/media?episodeId=private-episode","audioMimeType":"audio/mp4","visibility":"private","transcripts":[]}"#.utf8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([episode.id: episode]).write(to: directory.appendingPathComponent("episodes.json"))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent(PodcastDownloadStore.key(episode.id)))
        UserDefaults.standard.set([episode.id], forKey: indexKey)
        let store = PodcastDownloadStore()
        defer {
            store.configure(viewer: nil)
            for did in [viewer, otherViewer] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(PodcastDownloadStore.key(did)))
                UserDefaults.standard.removeObject(forKey: "podcast-download-index.\(PodcastDownloadStore.key(did))")
                UserDefaults.standard.removeObject(forKey: "podcast-download-tasks.\(PodcastDownloadStore.key(did))")
            }
        }
        store.configure(viewer: viewer)
        #expect(store.localURL(episode.id) != nil)
        #expect(store.episodes[episode.id]?.isPrivate == true)
        #expect(store.storageBytes == 3)
        #expect(store.exportFilename(for: episode) == "Private-Show- Episode.m4a")
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"private-show","title":"Show","sourceKind":"private-rss","hosts":[{"name":"Offline Host","imageUrl":"/v1/podcasts/artwork?assetId=host"}]}"#.utf8))
        store.remember(show)
        store.configure(viewer: nil)
        store.configure(viewer: viewer)
        #expect(store.shows[show.id]?.hosts?.first?.name == "Offline Host")
        store.configure(viewer: otherViewer)
        #expect(store.localURL(episode.id) == nil)
        #expect(store.episodes.isEmpty)
        #expect(store.shows.isEmpty)
    }

    @Test("Chapters preserve source timestamps, active art, and backward decoding")
    func chaptersAndHosts() throws {
        let episode = try JSONDecoder().decode(PodcastEpisode.self, from: Data(#"{"id":"e","showId":"s","title":"Episode","publishedAt":"2026-10-04T00:00:00Z","audioUrl":"https://example.com/a.mp3","transcripts":[],"chapters":[{"startSeconds":60,"title":"Second","artworkUrl":"https://example.com/chapter.jpg"},{"startSeconds":0,"title":"First"}]}"#.utf8))
        #expect(episode.activeChapter(at: 0)?.title == "First")
        #expect(episode.activeChapter(at: 59)?.title == "First")
        #expect(episode.activeChapter(at: 60)?.title == "Second")
        #expect(episode.activeChapter(at: 60)?.artworkUrl == "https://example.com/chapter.jpg")
        #expect(episode.activeChapter(at: -1) == nil)
        let restored = try JSONDecoder().decode(PodcastEpisode.self, from: JSONEncoder().encode(episode))
        #expect(restored.chapters == episode.chapters)
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"s","title":"Show","sourceKind":"rss","hosts":[{"name":"Host","role":"Host","imageUrl":"https://example.com/host.jpg"}]}"#.utf8))
        #expect(show.hosts?.first?.name == "Host")
        #expect(try JSONDecoder().decode(PodcastShow.self, from: JSONEncoder().encode(show)).hosts == show.hosts)
        #expect(PodcastPlaybackController.normalizedSpeed(0.5) == 0.75)
        #expect(PodcastPlaybackController.normalizedSpeed(3) == 2)
    }

    @Test("Artwork ownership changes even when two viewers request the same private URL")
    func artworkViewerIdentity() {
        let url = "/v1/podcasts/image?showId=private-show&kind=artwork"
        #expect(PodcastArtworkIdentity(viewer: "did:plc:alice", url: url) != PodcastArtworkIdentity(viewer: "did:plc:bob", url: url))
        #expect(PodcastArtworkIdentity(viewer: "did:plc:alice", url: url) != PodcastArtworkIdentity(viewer: nil, url: url))
        #expect(PodcastArtworkIdentity(viewer: "did:plc:alice", url: url) != PodcastArtworkIdentity(viewer: "did:plc:alice", url: url + "&index=1"))
    }

    @Test("Only completed v2 silence maps are applied")
    func silenceAnalysisVersion() throws {
        func analysis(_ version: String?, status: String = "complete") throws -> PodcastSilenceAnalysis {
            var json: [String: Any] = ["status": status, "intervals": [["start": 1, "end": 2]]]
            if let version { json["analysisVersion"] = version }
            return try JSONDecoder().decode(PodcastSilenceAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(try analysis(nil).currentIntervals == nil)
        #expect(try analysis("v1").currentIntervals == nil)
        #expect(try analysis("v2", status: "processing").currentIntervals == nil)
        #expect(try analysis("v2").currentIntervals?.first?.start == 1)
    }

    @Test("Library search retains pagination across empty scan pages and deduplicates results")
    @MainActor
    func searchPagination() async throws {
        let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"show","title":"Show","sourceKind":"rss"}"#.utf8))
        let model = PodcastSearchModel()
        let identity = PodcastSearchIdentity(viewer: "did:plc:alice", query: "  show  ")
        #expect(identity.normalizedQuery == "show")
        #expect(!PodcastSearchIdentity(viewer: "did:plc:alice", query: "s").isValid)
        await model.search(identity, debounce: false) { _, cursor in
            #expect(cursor == nil)
            return PodcastSearchPage(shows: [], episodes: [], cursor: "next", hasMore: true)
        }
        #expect(model.hasMore)
        await model.loadMore { received, cursor in
            #expect(received == identity)
            #expect(cursor == "next")
            return PodcastSearchPage(shows: [show, show], episodes: [], cursor: nil, hasMore: false)
        }
        #expect(model.shows.count == 1)
        #expect(!model.hasMore)
    }

    @Test("A previous viewer's suspended search cannot replace current results")
    @MainActor
    func searchOwnershipRace() async throws {
        let model = PodcastSearchModel()
        let alice = PodcastSearchIdentity(viewer: "did:plc:alice", query: "private")
        let bob = PodcastSearchIdentity(viewer: "did:plc:bob", query: "other")
        var pending: CheckedContinuation<PodcastSearchPage, Never>?
        let first = Task { @MainActor in
            await model.search(alice, debounce: false) { _, _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await model.search(bob, debounce: false) { _, _ in
            PodcastSearchPage(shows: [], episodes: [], cursor: "bob-next", hasMore: true)
        }
        let privateShow = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"private","title":"Private Show","sourceKind":"private-rss"}"#.utf8))
        pending?.resume(returning: PodcastSearchPage(shows: [privateShow], episodes: [], cursor: nil, hasMore: false))
        await first.value
        #expect(model.identity == bob)
        #expect(model.shows.isEmpty)
        #expect(model.hasMore)
        #expect(!model.loading)
    }

    @Test("Switching to Search clears private library queries atomically")
    func discoveryScopePrivacy() {
        #expect(PodcastSearchScope.discover.title == "Search")
        let library = PodcastSearchInput(query: "private subscriber episode", scope: .library)
        let directory = library.selecting(.discover)
        #expect(directory.query.isEmpty)
        #expect(directory.scope == .discover)
        #expect(!PodcastSearchIdentity(viewer: "did:plc:alice", query: directory.query, scope: directory.scope).isValid)
        #expect(library.selecting(.library).query == library.query)
        let request = PodcastSearchIdentity(viewer: "did:plc:alice", query: "  technology  ", scope: .discover, kind: "episodes", showId: "private-show").requestBody(cursor: "private-cursor")
        #expect(request["scope"]?.string == "directory")
        #expect(request["query"]?.string == "technology")
        #expect(request["showId"] == nil)
        #expect(request["cursor"] == nil)
        #expect(request["kind"] == nil)
    }

    @Test("Podcast Index candidates replace library results without subscribing")
    @MainActor
    func directoryCandidateResults() async throws {
        let model = PodcastSearchModel()
        let page = try JSONDecoder().decode(PodcastSearchPage.self, from: Data(#"{"shows":[],"episodes":[],"candidates":[{"provider":"podcastindex","id":"123","title":"Technology Show","author":"Host","feedUrl":"https://example.com/feed.xml","artworkUrl":"https://example.com/art.jpg"}],"hasMore":false,"directoryLimit":50}"#.utf8))
        let privateShow = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"private","title":"Private Show","sourceKind":"private-rss"}"#.utf8))
        await model.search(PodcastSearchIdentity(viewer: "did:plc:alice", query: "private"), debounce: false) { _, _ in
            PodcastSearchPage(shows: [privateShow], episodes: [], cursor: nil, hasMore: false)
        }
        await model.search(PodcastSearchIdentity(viewer: "did:plc:alice", query: "technology", scope: .discover), debounce: false) { _, _ in page }
        #expect(model.shows.isEmpty)
        #expect(model.episodes.isEmpty)
        #expect(model.candidates.first?.provider == "podcastindex")
        #expect(model.candidates.first?.author == "Host")
        #expect(model.candidates.first?.feedUrl == "https://example.com/feed.xml")
        #expect(!model.hasMore)
    }

    @Test("Private listener state keeps intentional rewinds")
    func rewindsPersist() throws {
        var state = PodcastListenerState()
        state.progress["ep1"] = PodcastProgress(positionSeconds: 120, updatedAt: "2026-10-04T00:00:00Z", completed: false)
        state.progress["ep1"] = PodcastProgress(positionSeconds: 30, updatedAt: "2026-10-04T00:01:00Z", completed: false)
        let decoded = try JSONDecoder().decode(PodcastListenerState.self, from: JSONEncoder().encode(state))
        #expect(decoded.progress["ep1"]?.positionSeconds == 30)
    }

    @Test("Silence skipping preserves source timestamps and rejects invalid ranges")
    func silenceTimeline() {
        let interval = PodcastSilenceInterval(start: 10, end: 15)
        #expect(interval.destination(at: 9) == nil)
        #expect(interval.destination(at: 10) == 15)
        #expect(interval.destination(at: 15) == nil)
        #expect(PodcastSilenceInterval(start: 15, end: 10).destination(at: 15) == nil)
    }

    @Test("Download identities do not collide across viewers or episodes")
    func downloadOwnership() {
        #expect(PodcastDownloadStore.key("did:plc:alice") != PodcastDownloadStore.key("did:plc:bob"))
        #expect(PodcastDownloadStore.key("ep1") != PodcastDownloadStore.key("ep2"))
        #expect(PodcastDownloadStore.key("ep1") == PodcastDownloadStore.key("ep1"))
    }

    @Test("Restoring a missing background task exposes retry instead of permanent zero progress")
    @MainActor
    func interruptedDownloadRestoration() async throws {
        let viewer = "did:plc:podcast-test-\(UUID().uuidString)"
        let key = "podcast-download-tasks.\(PodcastDownloadStore.key(viewer))"
        UserDefaults.standard.set(["999999": "missing-episode"], forKey: key)
        let store = PodcastDownloadStore()
        defer {
            store.configure(viewer: nil)
            UserDefaults.standard.removeObject(forKey: key)
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PodcastDownloads/\(PodcastDownloadStore.key(viewer))")
            try? FileManager.default.removeItem(at: directory)
        }
        store.configure(viewer: viewer)
        for _ in 0..<100 where store.errors["missing-episode"] == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.progress["missing-episode"] == nil)
        #expect(store.errors["missing-episode"] != nil)
    }

    @Test("Clip sharing targets the matching API deployment")
    func clipSharingEnvironment() {
        let apiHost = URL(string: SocialWireAPIEnvironment.baseURLString)?.host
        let webHost = URL(string: SocialWireAPIEnvironment.webBaseURLString)?.host
        #expect(apiHost == "api." + (webHost ?? ""))
    }

    @Test("Podcasts are absent until the server enables the feature")
    func navigationGate() {
        #expect(!NewsTab.available(wire: true, circle: true).contains(.podcasts))
        #expect(NewsTab.available(wire: true, circle: true, podcasts: true).contains(.podcasts))
        #expect(NewsPrimaryFeed.podcasts.newsTab == .podcasts)
    }
}
