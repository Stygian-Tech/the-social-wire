import Foundation
import Testing

@testable import ThinAppViewCore

struct PodcastPrivateCatalogTests {
  @Test func tokenizedHTTPSIsPrivateOnlyAndUserinfoRemainsUnsupported() {
    let token = "https://feeds.example.com/subscriber/opaque?token=secret&signature=private"
    #expect(PodcastPrivateCatalog.isAllowedURL(token))
    #expect(!PodcastRSSURL.isAllowed(token))
    #expect(!PodcastPrivateCatalog.isAllowedURL("http://feeds.example.com/rss?token=secret"))
    #expect(!PodcastPrivateCatalog.isAllowedURL("https://user:password@feeds.example.com/rss"))
  }

  @Test func privateIdentityIsViewerScopedAndClientProjectionHasNoSourceCredentials() throws {
    let url = "https://feeds.example.com/rss?token=private-secret"
    let show = PodcastShow(id: "public-show", title: "Private Show", description: "Subscribe <a href=\"https://feeds.example.com/rss?token=private-secret\">here</a>", feedUrl: url, sourceKind: "rss", guid: "common-guid")
    let episode = PodcastEpisode(id: "public-episode", showId: show.id, title: "Private Episode", description: "Listen https://media.example.com/a.mp3?token=private-secret", publishedAt: "2026-10-06T00:00:00Z", audioUrl: "https://media.example.com/a.mp3?token=private-secret", guid: "original-guid", transcripts: [PodcastTranscript(url: "https://media.example.com/a.vtt?token=private-secret", type: "text/vtt")])
    let owner = PodcastPrivateCatalog.scope(viewer: "did:plc:owner", feedURL: url, show: show, episodes: [episode])
    let other = PodcastPrivateCatalog.scope(viewer: "did:plc:other", feedURL: url, show: show, episodes: [episode])
    #expect(owner.show.id != other.show.id)
    #expect(owner.episodes[0].id != other.episodes[0].id)
    #expect(owner.episodes[0].guid == "original-guid")
    #expect(owner.episodes[0].audioUrl == episode.audioUrl)
    #expect(owner.show.sourceKind == "private-rss")
    let visibleShow = PodcastPrivateCatalog.visible(owner.show)
    let visibleEpisode = PodcastPrivateCatalog.visible(owner.episodes[0])
    let encoder = JSONEncoder()
    #expect(!String(decoding: try encoder.encode(visibleShow), as: UTF8.self).contains("private-secret"))
    #expect(!String(decoding: try encoder.encode(visibleEpisode), as: UTF8.self).contains("private-secret"))
    #expect(visibleEpisode.audioUrl == "/v1/podcasts/media?episodeId=" + owner.episodes[0].id)
    #expect(visibleShow.visibility == "private")
    #expect(visibleEpisode.visibility == "private")
  }
}
