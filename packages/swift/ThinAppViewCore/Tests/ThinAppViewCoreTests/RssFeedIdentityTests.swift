import Foundation
import Testing
import ThinAppViewCore

@Suite("RssFeedIdentity")
struct RssFeedIdentityTests {
  @Test("publication and entry ids round-trip with web shape")
  func publicationEntryRoundTrip() {
    let feed = "https://example.com/feed.xml"
    let pubId = RssFeedIdentity.rssPublicationId(from: feed)
    #expect(pubId.hasPrefix(RssFeedLexicons.publicationPrefix))
    #expect(RssFeedIdentity.normalizedFeedUrl(fromRssPublicationId: pubId) == feed)

    let stable = "guid:abc123"
    let entryId = RssFeedIdentity.rssEntryId(normalizedFeedUrl: feed, stableItemKey: stable)
    #expect(entryId.hasPrefix(RssFeedLexicons.entryPrefix))
  }

  @Test("stable item key prefers guid then link")
  func stableItemKey() {
    let withGuid = ParsedRssItem(
      guid: "abc",
      title: "T",
      link: "https://example.com/a",
      summary: nil,
      contentHTML: nil,
      publishedAtISO: "2026-01-01T00:00:00.000Z",
      thumbnailUrl: nil
    )
    #expect(RssFeedIdentity.stableItemKey(from: withGuid) == "guid:abc")

    let withLink = ParsedRssItem(
      guid: nil,
      title: "T",
      link: "https://example.com/a",
      summary: nil,
      contentHTML: nil,
      publishedAtISO: "2026-01-01T00:00:00.000Z",
      thumbnailUrl: nil
    )
    #expect(RssFeedIdentity.stableItemKey(from: withLink) == "link:https://example.com/a")
  }

  @Test("blocks localhost feed fetch")
  func blockedHost() {
    #expect(!RssFeedIdentity.isFetchableFeedUrl("https://127.0.0.1/feed.xml"))
    #expect(RssFeedIdentity.isFetchableFeedUrl("https://example.com/rss"))
  }
}

@Suite("RssFeedParser")
struct RssFeedParserTests {
  @Test("parses minimal RSS channel")
  func parseRss() {
    let xml = """
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <title>Example</title>
        <item>
          <title>Post One</title>
          <link>https://example.com/one</link>
          <guid>one</guid>
          <pubDate>Fri, 22 May 2026 12:00:00 +0000</pubDate>
          <description>Snippet</description>
        </item>
      </channel></rss>
      """
    let feed = RssFeedParser(data: Data(xml.utf8)).parse()
    #expect(feed.items.count == 1)
    #expect(feed.items[0].title == "Post One")
    #expect(feed.items[0].guid == "one")
  }
}
