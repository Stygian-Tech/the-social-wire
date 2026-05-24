import Foundation
import Testing
import ThinAppViewCore

@Suite("RssFeedThumbnailExtractor")
struct RssFeedThumbnailExtractorTests {
  @Test("extracts img src from HTML description")
  func htmlImage() {
    let url = RssFeedThumbnailExtractor.resolveThumbnail(
      storedURL: nil,
      contentHTML: nil,
      summary: #"<p>Hello</p><img src="https://cdn.example/photo.jpg" alt="" />"#,
      articleLink: "https://example.com/post",
      feedURL: "https://example.com/feed.xml"
    )
    #expect(url == "https://cdn.example/photo.jpg")
  }

  @Test("resolves relative image URLs against article link")
  func relativeImage() {
    let url = RssFeedThumbnailExtractor.resolveThumbnail(
      storedURL: "/images/thumb.png",
      contentHTML: nil,
      summary: nil,
      articleLink: "https://example.com/post",
      feedURL: nil
    )
    #expect(url == "https://example.com/images/thumb.png")
  }

  @Test("rejects audio enclosures without image type")
  func rejectsAudioEnclosure() {
    #expect(
      !RssFeedThumbnailExtractor.acceptsMediaURL(
        url: "https://cdn.example/episode.mp3",
        type: "audio/mpeg",
        medium: nil
      )
    )
  }
}

@Suite("RssFeedParser thumbnails")
struct RssFeedParserThumbnailTests {
  @Test("parses media thumbnail and itunes image")
  func mediaAndItunes() {
    let xml = """
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel><title>Feed</title>
        <item>
          <title>Thumb Post</title>
          <link>https://example.com/a</link>
          <guid>a</guid>
          <pubDate>Fri, 22 May 2026 12:00:00 +0000</pubDate>
          <media:thumbnail url="https://cdn.example/thumb.jpg" />
        </item>
        <item>
          <title>Itunes Post</title>
          <link>https://example.com/b</link>
          <guid>b</guid>
          <pubDate>Fri, 22 May 2026 11:00:00 +0000</pubDate>
          <itunes:image href="https://cdn.example/itunes.jpg" />
        </item>
      </channel></rss>
      """
    let feed = RssFeedParser(data: Data(xml.utf8), feedURL: "https://example.com/feed.xml").parse()
    #expect(feed.items.count == 2)
    #expect(feed.items.contains { $0.thumbnailUrl == "https://cdn.example/thumb.jpg" })
    #expect(feed.items.contains { $0.thumbnailUrl == "https://cdn.example/itunes.jpg" })
  }

  @Test("falls back to description img tag")
  func descriptionImage() {
    let xml = """
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Feed</title>
        <item>
          <title>HTML Post</title>
          <link>https://example.com/c</link>
          <guid>c</guid>
          <pubDate>Fri, 22 May 2026 10:00:00 +0000</pubDate>
          <description><![CDATA[<img src="https://cdn.example/inline.jpg" />]]></description>
        </item>
      </channel></rss>
      """
    let feed = RssFeedParser(data: Data(xml.utf8), feedURL: "https://example.com/feed.xml").parse()
    #expect(feed.items.first?.thumbnailUrl == "https://cdn.example/inline.jpg")
  }
}
