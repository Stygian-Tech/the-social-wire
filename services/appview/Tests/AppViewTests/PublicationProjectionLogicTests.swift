import Foundation
import GatewayCore
import Testing

@testable import AppView

@Suite("PublicationProjectionLogic")
struct PublicationProjectionLogicTests {
  @Test("subscription keys include cross-lexicon publication aliases")
  func subscriptionAliasKeys() {
    var keys = Set<String>()
    PublicationProjectionLogic.addPublicationSubscriptionLookupKeys(
      into: &keys,
      value: "at://did:plc:abc/site.standard.publication/rkey1"
    )
    #expect(keys.contains("at://did:plc:abc/com.standard.publication/rkey1"))
  }

  @Test("rss rows only include sourceType rss subscriptions")
  func rssRowsFilterSourceType() {
    let rows = PublicationProjectionLogic.skyreaderRows(
      from: [
        (
          uri: "at://did:plc:viewer/app.skyreader.feed.subscription/r1",
          value: PdsRecordJSON(values: [
            "feedUrl": "https://example.com/feed.xml",
            "sourceType": "rss",
            "title": "Example",
          ])
        ),
        (
          uri: "at://did:plc:viewer/app.skyreader.feed.subscription/r2",
          value: PdsRecordJSON(values: [
            "feedUrl": "https://other.com/feed.xml",
            "sourceType": "bluesky",
          ])
        ),
      ]
    )
    #expect(rows.count == 1)
    #expect(rows[0].title == "Example")
    #expect(rows[0].authorDid == PublicationLexicons.rssAuthorDid)
  }

  @Test("rss publication id decodes normalized feed url")
  func rssPublicationIdRoundTrip() {
    let feed = "https://example.com/feed.xml"
    let pubId = PublicationProjectionLogic.rssPublicationId(from: feed)
    #expect(PublicationProjectionLogic.normalizedFeedUrlFromRssPublicationId(pubId) == feed)
  }
}
