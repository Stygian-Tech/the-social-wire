import Foundation
import Testing
@testable import ThinAppViewCore

struct PodcastMetadataTests {
  @Test func rssSuppliedPeopleCloudAndInlineChapters() throws {
    let xml = """
      <rss xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:psc="http://podlove.org/simple-chapters"><channel><title>Show</title>
      <podcast:person img="https://example.com/host.jpg" href="https://example.com/host">Host</podcast:person>
      <podcast:person role="guest">Guest</podcast:person>
      <item><guid>original-guid</guid><title>Episode</title><enclosure url="https://example.com/a.mp3" type="audio/mpeg"/>
      <podcast:chapters url="https://example.com/chapters.json" type="application/json+chapters"/>
      <psc:chapters><psc:chapter start="00:00:00.000" title="Intro" image="https://example.com/intro.jpg"/><psc:chapter start="01:02.500" title="Next" href="https://example.com/next"/></psc:chapters>
      </item></channel></rss>
      """
    let value = try PodcastRSSParser(feedURL: "https://example.com/rss").parse(Data(xml.utf8))
    #expect(value.show.hosts.map(\.name) == ["Host"])
    #expect(value.show.hosts.first?.imageUrl == "https://example.com/host.jpg")
    #expect(value.episodes[0].guid == "original-guid")
    #expect(value.episodes[0].chapterSourceUrl == "https://example.com/chapters.json")
    #expect(value.episodes[0].chapters.map(\.startSeconds) == [0, 62.5])
    #expect(value.episodes[0].chapters[0].artworkUrl == "https://example.com/intro.jpg")
  }
  @Test func chapterJSONSortsAndRejectsInvalidOrHiddenTimes() {
    let json = #"{"version":"1.2.0","chapters":[{"startTime":3,"title":"Later","img":"https://example.com/chapter.png"},{"startTime":0,"title":"Intro"},{"startTime":-1},{"startTime":1,"toc":false},{"startTime":10},{"startTime":"bad"}]}"#
    let value = PodcastChapterParser.parse(Data(json.utf8), duration: 10)
    #expect(value.map(\.startSeconds) == [0,3])
    #expect(value[1].artworkUrl == "https://example.com/chapter.png")
    #expect(PodcastChapterParser.safeURL("https://user:secret@example.com/photo") == nil)
  }
  @Test func protocolRecordsRetainSuppliedHostsAndChapters() throws {
    let uri = "at://did:plc:publisher/place.pod.show/show"
    let show = try PodcastProtocolAdapter.show(uri: uri, record: ["title": "Show", "imageUrl": "https://example.com/show.png", "hosts": [["name": "Host", "role": "host", "imageUrl": "https://example.com/host.png"]]])
    let episode = try #require(PodcastProtocolAdapter.episode(uri: "at://did:plc:publisher/place.pod.episode/episode", record: ["showUri": uri, "title": "Episode", "publishedAt": "2026-10-05T00:00:00Z", "audioUrl": "https://example.com/a.mp3", "audioMimeType": "audio/mpeg", "chapters": [["startTime": 0.0, "title": "Intro", "img": "https://example.com/chapter.png"]]], show: show))
    #expect(show.hosts.first?.imageUrl == "https://example.com/host.png")
    #expect(episode.chapters.first?.artworkUrl == "https://example.com/chapter.png")
    #expect(episode.showArtworkUrl == show.artworkUrl)
  }
  @Test func legacyCatalogDecodesWithoutNewArrays() throws {
    let show = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"show","title":"Show","sourceKind":"rss"}"#.utf8))
    let episode = try JSONDecoder().decode(PodcastEpisode.self, from: Data(#"{"id":"episode","showId":"show","title":"Episode","publishedAt":"2026-10-05T00:00:00Z","audioUrl":"https://example.com/a.mp3","transcripts":[]}"#.utf8))
    #expect(show.hosts.isEmpty && episode.chapters.isEmpty)
  }
  @Test func privateMetadataUsesOpaqueOwnerImagePathsAndRedactsSourceLinks() throws {
    let raw = "https://example.com/image?token=private-secret"
    let show = PodcastShow(id: "private-podcast:show:owner", title: "Show", artworkUrl: raw, sourceKind: "private-rss", visibility: "private", hosts: [PodcastPerson(name: "Host", imageUrl: raw, url: raw)])
    let episode = PodcastEpisode(id: "private-podcast:episode:owner", showId: show.id, title: "Episode", publishedAt: "2026-10-05T00:00:00Z", audioUrl: raw, artworkUrl: raw, transcripts: [], visibility: "private", chapters: [PodcastChapter(startSeconds: 0, title: "Intro", artworkUrl: raw, url: raw)], chapterSourceUrl: raw, showArtworkUrl: raw)
    let safeShow = PodcastPrivateCatalog.visible(show), safeEpisode = PodcastPrivateCatalog.visible(episode)
    #expect(safeShow.hosts[0].imageUrl?.hasPrefix("/v1/podcasts/image?") == true)
    #expect(safeEpisode.chapters[0].artworkUrl?.contains("kind=chapter") == true)
    #expect(safeEpisode.chapterSourceUrl == nil && safeEpisode.chapters[0].url == nil)
    #expect(!String(decoding: try JSONEncoder().encode(safeShow), as: UTF8.self).contains("private-secret"))
    #expect(!String(decoding: try JSONEncoder().encode(safeEpisode), as: UTF8.self).contains("private-secret"))
  }
  @Test func speedsNormalizeLegacyValuesWithoutChangingRewindProgress() {
    var state = PodcastListenerState()
    state.progress["episode"] = PodcastProgress(positionSeconds: 5, updatedAt: "2026-10-05T00:00:00Z")
    for (speed, expected) in [(0.5,0.75),(3.0,2.0),(1.3,1.25)] {
      state.playbackSpeed = speed
      #expect(!state.validate())
      state.normalizePlaybackSpeed()
      #expect(state.playbackSpeed == expected)
      #expect(state.progress["episode"]?.positionSeconds == 5)
      #expect(state.validate())
    }
  }
  @Test func imageBytesRejectActiveOrNonImagePayloads() throws {
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5X8AAAAASUVORK5CYII="))
    #expect(PodcastImage.mimeType(png) == "image/png")
    #expect(PodcastImage.mimeType(Data("<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>".utf8)) == nil)
    #expect(PodcastImage.mimeType(Data("<html>not an image</html>".utf8)) == nil)
    #expect(PodcastImage.mimeType(Data([137,80,78,71,13,10,26,10])) == nil)
  }
}
