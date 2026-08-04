import Foundation
import GatewayCore
import Testing

@testable import AppView

@Suite("PublicationProjectionLogic")
struct PublicationProjectionLogicTests {
  @Test("normalizeAtRepoParam decodes URL-encoded AT-URIs")
  func normalizeAtRepoEncodedAtUri() {
    let encoded = "at%3A%2F%2Fdid%3Aplc%3Aabc%2Fsite.standard.publication%2Frkey1"
    let expected = "at://did:plc:abc/site.standard.publication/rkey1"
    #expect(PublicationProjectionLogic.normalizeAtRepoParam(encoded) == expected)
  }

  @Test("publication id lookup keys include cross-lexicon aliases")
  func publicationIdLookupAliasKeys() {
    let keys = Set(
      PublicationProjectionLogic.publicationIdLookupKeys(
        for: "at://did:plc:abc/site.standard.publication/rkey1"
      )
    )
    #expect(keys.contains("at://did:plc:abc/com.standard.publication/rkey1"))
  }

  @Test("publication ids match across encoding and alias keys")
  func publicationIdsMatchAcrossAliases() {
    let canonical = "at://did:plc:abc/site.standard.publication/rkey1"
    let alias = "at://did:plc:abc/com.standard.publication/rkey1"
    #expect(PublicationProjectionLogic.publicationIdsMatch(canonical, alias))
  }

  @Test("duplicate publication prefs do not crash lookup map")
  func duplicatePublicationPrefsUseHighestUri() {
    let first = PublicationPrefsRecordDTO(
      uri: "at://did:plc:viewer/app.thesocialwire.publicationPrefs/aaa",
      publicationId: "did:plc:23cnpffmuf4vkpsnwhgyvljw",
      value: ["folderId": AnyCodable("old")]
    )
    let second = PublicationPrefsRecordDTO(
      uri: "at://did:plc:viewer/app.thesocialwire.publicationPrefs/zzz",
      publicationId: "did:plc:23cnpffmuf4vkpsnwhgyvljw",
      value: ["folderId": AnyCodable("new")]
    )

    let map = PublicationProjectionLogic.prefsByPublicationId([second, first])

    #expect(map.count == 1)
    #expect(map["did:plc:23cnpffmuf4vkpsnwhgyvljw"]?.uri == second.uri)
    #expect(map["did:plc:23cnpffmuf4vkpsnwhgyvljw"]?.value["folderId"]?.value as? String == "new")
  }

  @Test("hidden publication prefs exclude canonical and aliased rows")
  func hiddenPublicationPrefsExcludeRows() {
    let hidden = PublicationPrefsRecordDTO(
      uri: "at://did:plc:viewer/app.thesocialwire.publicationPrefs/pref1",
      publicationId: "at://did:plc:author/site.standard.publication/pub1",
      value: ["hidden": AnyCodable(true)]
    )
    let rows = [
      ProjectionDiscoveredRow(
        publicationId: "at://did:plc:author/com.standard.publication/pub1",
        subscriptionPublicationId: nil,
        authorDid: "did:plc:author",
        authorHandle: "author.test",
        title: "Hidden",
        iconUrl: nil,
        avatarUrl: nil,
        discoveredAt: Date()
      ),
      ProjectionDiscoveredRow(
        publicationId: "did:plc:visible",
        subscriptionPublicationId: nil,
        authorDid: "did:plc:visible",
        authorHandle: "visible.test",
        title: "Visible",
        iconUrl: nil,
        avatarUrl: nil,
        discoveredAt: Date()
      ),
    ]

    let filtered = PublicationProjectionLogic.filterHiddenPublications(rows, prefs: [hidden])

    #expect(filtered.map(\.publicationId) == ["did:plc:visible"])
  }

  @Test("newest publication preference can unhide an older duplicate")
  func newestPublicationPrefCanUnhideDuplicate() {
    let publicationId = "did:plc:publication"
    let olderHidden = PublicationPrefsRecordDTO(
      uri: "at://did:plc:viewer/app.thesocialwire.publicationPrefs/aaa",
      publicationId: publicationId,
      value: ["hidden": AnyCodable(true)]
    )
    let newerVisible = PublicationPrefsRecordDTO(
      uri: "at://did:plc:viewer/app.thesocialwire.publicationPrefs/zzz",
      publicationId: publicationId,
      value: ["hidden": AnyCodable(false)]
    )
    let row = ProjectionDiscoveredRow(
      publicationId: publicationId,
      subscriptionPublicationId: nil,
      authorDid: publicationId,
      authorHandle: "publication.test",
      title: "Visible",
      iconUrl: nil,
      avatarUrl: nil,
      discoveredAt: Date()
    )

    let filtered = PublicationProjectionLogic.filterHiddenPublications(
      [row],
      prefs: [newerVisible, olderHidden]
    )

    #expect(filtered == [row])
  }

  @Test("viewer's bare-DID content fallback does not auto-subscribe to their whole repo")
  func ownedContentFallbackRowIsNotAutoSubscribed() {
    let viewerDid = "did:plc:viewer"
    // Mirrors PublicationFollowDiscovery.discoverAuthor's discoveryContentCollections
    // fallback: a viewer with loose site.standard.document records but no
    // site.standard.publication container gets a bare-DID pseudo-publication row with
    // no subscriptionPublicationId (nothing addressable to subscribe to).
    let looseContentRow = ProjectionDiscoveredRow(
      publicationId: viewerDid,
      subscriptionPublicationId: nil,
      authorDid: viewerDid,
      authorHandle: "You",
      title: "My Publications",
      iconUrl: nil,
      avatarUrl: nil,
      discoveredAt: Date()
    )
    let realPublicationRow = ProjectionDiscoveredRow(
      publicationId: "at://did:plc:viewer/site.standard.publication/pub1",
      subscriptionPublicationId: "at://did:plc:viewer/site.standard.publication/pub1",
      authorDid: viewerDid,
      authorHandle: "You",
      title: "My Real Site",
      iconUrl: nil,
      avatarUrl: nil,
      discoveredAt: Date()
    )

    let segmented = PublicationProjectionLogic.segmentDiscovery(
      [looseContentRow, realPublicationRow],
      viewerDid: viewerDid,
      subscriptionKeys: []
    )

    #expect(segmented.graphSubscribed.map(\.publicationId) == [realPublicationRow.publicationId])
    #expect(segmented.followOwnedUnsubscribed.map(\.publicationId) == [looseContentRow.publicationId])
  }

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

  @Test("rss publication id preserves meaningful feed query")
  func rssPublicationIdPreservesFeedQuery() {
    let feed = "https://basicappleguy.com/basicappleblog?format=rss"
    let normalized = PublicationProjectionLogic.normalizeRssFeedUrl(feed)
    let pubId = PublicationProjectionLogic.rssPublicationId(from: normalized!)

    #expect(normalized == feed)
    #expect(PublicationProjectionLogic.normalizedFeedUrlFromRssPublicationId(pubId) == feed)
  }
}
