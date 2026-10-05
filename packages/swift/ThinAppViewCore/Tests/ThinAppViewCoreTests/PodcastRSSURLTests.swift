import Testing

@testable import ThinAppViewCore

struct PodcastRSSURLTests {
  @Test(arguments: [
    "https://example.com/podcast.xml",
    "https://example.com/?feed=rss2",
    "https://example.com/podcast?format=xml&feed=atom",
    "https://example.com/podcast?format=RSS2",
  ])
  func allowsPublicFeeds(url: String) {
    #expect(PodcastRSSURL.isAllowed(url))
  }

  @Test(arguments: [
    "http://example.com/podcast.xml",
    "example.com/podcast.xml",
    "https://viewer:password@example.com/podcast.xml",
    "https://viewer@example.com/podcast.xml",
    "https://example.com/podcast.xml?token=secret",
    "https://example.com/podcast.xml?auth=secret",
    "https://example.com/podcast.xml?key=secret",
    "https://example.com/podcast.xml?password=secret",
    "https://example.com/podcast.xml?%74oken=secret",
    "https://example.com/podcast.xml?feed=rss2&signature=secret",
    "https://example.com/podcast.xml?unknown=value",
    "https://example.com/podcast.xml?format=credential",
    "https://example.com/podcast.xml?feed=secret",
    "https://example.com/podcast.xml?format",
  ])
  func rejectsPrivateOrUnrecognizedSourcesBeforeNormalization(url: String) {
    #expect(!PodcastRSSURL.isAllowed(url))
  }
}
