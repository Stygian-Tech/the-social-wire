import Foundation
import Testing
@testable import App

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

  @Test("orphan graph subscriptions exclude rows already matched")
  func orphanUris() {
    let existing = [
      ProjectionDiscoveredRow(
        publicationId: "at://did:plc:author/site.standard.publication/pub1",
        subscriptionPublicationId: "at://did:plc:author/site.standard.publication/pub1",
        authorDid: "did:plc:author",
        authorHandle: nil,
        title: "Pub",
        iconUrl: nil,
        avatarUrl: nil,
        discoveredAt: Date()
      ),
    ]
    let uris = PublicationProjectionLogic.orphanGraphSubscriptionUris(
      subscriptions: [
        ["publication": "at://did:plc:author/site.standard.publication/pub1"],
        ["publication": "at://did:plc:other/site.standard.publication/other"],
      ],
      existingRows: existing
    )
    #expect(uris == ["at://did:plc:other/site.standard.publication/other"])
  }

  @Test("segmentDiscovery splits subscribed and following")
  func segmentDiscovery() {
    let discovered = [
      ProjectionDiscoveredRow(
        publicationId: "did:plc:viewer",
        subscriptionPublicationId: nil,
        authorDid: "did:plc:viewer",
        authorHandle: nil,
        title: "Mine",
        iconUrl: nil,
        avatarUrl: nil,
        discoveredAt: Date()
      ),
      ProjectionDiscoveredRow(
        publicationId: "at://did:plc:friend/site.standard.publication/f1",
        subscriptionPublicationId: "at://did:plc:friend/site.standard.publication/f1",
        authorDid: "did:plc:friend",
        authorHandle: nil,
        title: "Friend sub",
        iconUrl: nil,
        avatarUrl: nil,
        discoveredAt: Date()
      ),
      ProjectionDiscoveredRow(
        publicationId: "at://did:plc:stranger/site.standard.publication/s1",
        subscriptionPublicationId: "at://did:plc:stranger/site.standard.publication/s1",
        authorDid: "did:plc:stranger",
        authorHandle: nil,
        title: "Stranger",
        iconUrl: nil,
        avatarUrl: nil,
        discoveredAt: Date()
      ),
    ]

    var subKeys = Set<String>()
    PublicationProjectionLogic.addPublicationSubscriptionLookupKeys(
      into: &subKeys,
      value: "at://did:plc:friend/site.standard.publication/f1"
    )

    let segmented = PublicationProjectionLogic.segmentDiscovery(
      discovered,
      viewerDid: "did:plc:viewer",
      subscriptionKeys: subKeys
    )
    #expect(segmented.graphSubscribed.count == 2)
    #expect(segmented.followOwnedUnsubscribed.count == 1)
    #expect(segmented.followOwnedUnsubscribed[0].publicationId.contains("stranger"))
  }
}
