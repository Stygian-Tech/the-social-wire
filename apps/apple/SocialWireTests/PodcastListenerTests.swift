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
