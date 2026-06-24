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
