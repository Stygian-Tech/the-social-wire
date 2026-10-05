import Foundation
import Testing

@testable import ThinAppViewCore

struct PodcastTests {
  @Test func rssRetainsAudioAndSuppliedTranscriptsWithoutArticleCaps() throws {
    let items = (0..<205).map {
      "<item><guid>episode-\($0)</guid><title>Episode \($0)</title><enclosure url='https://media.example/\($0).mp3' type='audio/mpeg'/><itunes:duration>1:02:03</itunes:duration><podcast:transcript url='https://example.com/\($0).vtt' type='text/vtt'/></item>"
    }.joined()
    let rss =
      "<rss xmlns:itunes='urn:itunes' xmlns:podcast='urn:podcast'><channel><title>Show</title><podcast:guid>show-guid</podcast:guid>\(items)</channel></rss>"
    let result = try PodcastRSSParser(feedURL: "https://example.com/feed.xml").parse(Data(rss.utf8))
    #expect(result.show.title == "Show")
    #expect(result.show.guid == "show-guid")
    #expect(result.episodes.count == 205)
    #expect(result.episodes[0].durationSeconds == 3723)
    #expect(result.episodes[0].transcripts[0].type == "text/vtt")
    let repeated = try PodcastRSSParser(feedURL: "https://other.example/feed.xml").parse(
      Data(rss.utf8))
    #expect(result.show.id == repeated.show.id)
    #expect(result.episodes[0].id == repeated.episodes[0].id)
  }
  @Test func rssRejectsVideoAndKeepsEpisodeGuidIdentityAcrossURLChanges() throws {
    func parse(_ url: String) throws -> (show: PodcastShow, episodes: [PodcastEpisode]) {
      let xml =
        "<rss><channel><title>Show</title><item><guid>constant</guid><title>E</title><enclosure url='\(url)' type='audio/mpeg'/></item><item><enclosure url='https://example.com/video.mp4' type='video/mp4'/></item></channel></rss>"
      return try PodcastRSSParser(feedURL: "https://example.com/rss").parse(Data(xml.utf8))
    }
    let a = try parse("https://example.com/a.mp3")
    let b = try parse("https://example.com/new.mp3")
    #expect(a.episodes.count == 1)
    #expect(a.episodes[0].id == b.episodes[0].id)
  }
  @Test(arguments: [
    "", "<rss><channel>",
    "<rss><channel><title>Incomplete Show</title></channel>",
    "<rss><channel><item><guid>original-guid</guid><enclosure url='https://example.com/a.mp3' type='audio/mpeg'/></item></channel>",
    "<rss><channel></rss>",
    "<rss><channel/></rss><rss/>",
  ])
  func malformedRSSFailsInsteadOfPartialCatalog(xml: String) {
    #expect(throws: PodcastParseError.self) {
      try PodcastRSSParser(feedURL: "https://example.com/rss").parse(Data(xml.utf8))
    }
  }
  @Test func failedParseCannotReusePreviousCompleteDocument() throws {
    let parser = PodcastRSSParser(feedURL: "https://example.com/rss")
    let valid =
      "<rss xmlns:podcast='urn:podcast'><channel><title>Show</title><podcast:guid>original-show-guid</podcast:guid><item><guid>original-item-guid</guid><enclosure url='https://example.com/a.mp3' type='audio/mpeg'/></item></channel></rss>"
    let first = try parser.parse(Data(valid.utf8))
    #expect(first.show.guid == "original-show-guid")
    #expect(first.episodes.first?.guid == "original-item-guid")
    #expect(throws: PodcastParseError.self) { try parser.parse(Data("<rss><channel>".utf8)) }
    let repeated = try parser.parse(Data(valid.utf8))
    #expect(repeated.show.id == first.show.id)
    #expect(repeated.episodes.count == 1)
    #expect(repeated.episodes.first?.id == first.episodes.first?.id)
  }
  @Test func vttAndSRTNormalizeSourceTimes() {
    let vtt =
      "WEBVTT\n\n00:01.250 --> 00:02.500\nHello <b>World</b>\n\n00:03.000 --> 00:04.000\nNext"
    let parsed = PodcastTranscriptParser.parse(Data(vtt.utf8), type: "text/vtt")
    #expect(parsed.cues.count == 2)
    #expect(parsed.cues[0].startSeconds == 1.25)
    #expect(parsed.cues[0].endSeconds == 2.5)
    #expect(parsed.cues[0].text == "Hello World")
    let srt = "1\n00:00:12,200 --> 00:00:14,500\nTest"
    #expect(
      PodcastTranscriptParser.parse(Data(srt.utf8), type: "application/x-subrip").cues.first?
        .startSeconds == 12.2)
  }
  @Test func JSONAndHTMLSuppliedTranscripts() {
    let json = "{\"segments\":[{\"startTime\":1.5,\"endTime\":3.0,\"text\":\"Hello\"}]}"
    #expect(
      PodcastTranscriptParser.parse(Data(json.utf8), type: "application/json").cues.first?
        .endSeconds == 3)
    #expect(
      PodcastTranscriptParser.parse(Data("<p>Hello &amp; Bye</p>".utf8), type: "text/html").text
        .contains("Hello & Bye"))
  }
  @Test func playbackPreferencesValidateAndIntentionalRewindRemainsValid() {
    var state = PodcastListenerState()
    state.playbackSpeed = 3
    state.progress["episode"] = PodcastProgress(
      positionSeconds: 20, updatedAt: "2026-10-05T00:00:00.123Z")
    #expect(state.validate())
    state.progress["episode"]?.positionSeconds = 5
    #expect(state.validate())
    state.playbackSpeed = 3.1
    #expect(!state.validate())
    state.playbackSpeed = 0.5
    #expect(state.validate())
    state.progress["episode"]?.positionSeconds = -1
    #expect(!state.validate())
  }
  @Test func protocolAdaptersFilterExactShowAndExcludeDrafts() throws {
    let uri = "at://did:plc:creator/live.voxport.podcast.series/show"
    let show = try PodcastProtocolAdapter.show(
      uri: uri, record: ["title": "Vox Show", "podcastGuid": "guid"])
    let record: [String: Any] = [
      "title": "Episode", "series": ["uri": uri], "audioUrl": "https://media.example/a.mp3",
      "audioType": "audio/mpeg", "publishedAt": "2026-10-01T00:00:00Z",
      "transcript": ["url": "https://example.com/a.vtt", "type": "text/vtt"],
    ]
    let episode = PodcastProtocolAdapter.episode(
      uri: "at://did:plc:creator/live.voxport.podcast.episode/episode", record: record, show: show)
    #expect(episode?.transcripts.count == 1)
    var other = record
    other["series"] = ["uri": uri + "other"]
    #expect(
      PodcastProtocolAdapter.episode(
        uri: "at://did:plc:creator/live.voxport.podcast.episode/episode", record: other, show: show)
        == nil)
    var draft = record
    draft.removeValue(forKey: "publishedAt")
    #expect(
      PodcastProtocolAdapter.episode(
        uri: "at://did:plc:creator/live.voxport.podcast.episode/draft", record: draft, show: show)
        == nil)
  }
}
