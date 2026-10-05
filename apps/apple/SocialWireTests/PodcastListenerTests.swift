import Foundation
import Testing
@testable import SocialWire

@Suite("Podcast listener contracts")
struct PodcastListenerTests {
    @Test("Playback speed preserves the supported quarter-step range")
    func playbackSpeedBounds() {
        #expect(PodcastPlaybackController.normalizedSpeed(0) == 0.5)
        #expect(PodcastPlaybackController.normalizedSpeed(5) == 3)
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
        store.configure(viewer: otherViewer)
        #expect(store.localURL(episode.id) == nil)
        #expect(store.episodes.isEmpty)
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
