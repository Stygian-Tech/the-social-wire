import Foundation
import Testing
@testable import SocialWire

@Suite("Semble support")
struct SembleSupportTests {
    @Test("OAuth requests and requires every Semble write grant")
    @MainActor
    func oauthScopes() {
        let expected = [
            "repo:network.cosmik.card?action=create&action=update&action=delete",
            "repo:network.cosmik.collection?action=create&action=update&action=delete",
            "repo:network.cosmik.collectionLink?action=create&action=update&action=delete",
            "repo:network.cosmik.collectionLinkRemoval?action=create&action=update&action=delete",
            "repo:network.cosmik.connection?action=create&action=update&action=delete",
        ]
        for scope in expected {
            #expect(ATProtoOAuthService.scopes.split(separator: " ").contains(Substring(scope)))
            #expect(ATProtoOAuthService.requiredFeatureScopes.contains(scope))
        }
    }

    @Test("Preferences decode Semble destination without losing legacy feed fields")
    func preferencesDecode() throws {
        let record = try JSONDecoder().decode(PreferencesRecord.self, from: Data(#"""
        {
          "$type":"app.thesocialwire.preferences",
          "readLaterService":"semble",
          "readLaterConnections":{"semble":{"collectionUri":"at://did:plc:viewer/network.cosmik.collection/abc","collectionName":"Read Next","connectedAt":"2026-08-30T12:00:00Z"}},
          "visibleFeeds":["read-later","subscribed"],
          "feedsWithUnreadCounts":["subscribed"],
          "rssArticleOpenMode":"native",
          "createdAt":"2026-08-30T12:00:00Z",
          "updatedAt":"2026-08-30T12:00:00Z"
        }
        """#.utf8))

        #expect(record.readLaterService == "semble")
        #expect(record.readLaterConnections?["semble"]?.collectionName == "Read Next")
        #expect(record.visibleFeeds == ["read-later", "subscribed"])
        #expect(record.feedsWithUnreadCounts == ["subscribed"])
        #expect(record.rssArticleOpenMode == "native")
    }

    @Test("Collection response preserves completeness and nullable record links")
    func collectionDecode() throws {
        let page = try JSONDecoder().decode(SembleCollectionItemsPage.self, from: Data(#"""
        {
          "collection":{"uri":"at://did:plc:viewer/network.cosmik.collection/abc","name":"Read Next","cardCount":1},
          "items":[{
            "id":"card-1","cardUri":"at://did:plc:other/network.cosmik.card/one","cardType":"URL",
            "url":"https://example.com/story","title":"Story","membership":null,
            "contributor":{"did":"did:plc:other","handle":"other.test"},
            "note":{"uri":null,"text":"A note","authorDid":"did:plc:other","editable":false},
            "unlinkAvailable":false
          }],
          "membershipComplete":false,"recordLinksComplete":false
        }
        """#.utf8))

        #expect(page.membershipComplete == false)
        #expect(page.recordLinksComplete == false)
        #expect(page.items.first?.membership == nil)
        #expect(page.items.first?.unlinkAvailable == false)
        #expect(page.items.first?.note?.uri == nil)
    }

    @Test("Connections allow a missing URI for read-only projected rows")
    func connectionsDecode() throws {
        let page = try JSONDecoder().decode(SembleConnectionsPage.self, from: Data(#"""
        {"connections":[{"uri":null,"source":"at://did:plc:a/network.cosmik.card/1","target":"at://did:plc:b/network.cosmik.card/2","authorDid":"did:plc:b","editable":false}]}
        """#.utf8))
        #expect(page.connections.count == 1)
        #expect(page.connections[0].uri == nil)
        #expect(page.connections[0].editable == false)
    }

    @Test("Connection writes use official string endpoints")
    func connectionRecordEncode() throws {
        let record = SembleConnectionRecord(
            type: SembleRecordCollection.connection,
            source: "at://did:plc:a/network.cosmik.card/1",
            target: "https://example.com/story",
            connectionType: "supports",
            note: nil,
            createdAt: "2026-08-30T12:00:00Z",
            updatedAt: "2026-08-30T12:00:00Z"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        #expect(object["source"] as? String == "at://did:plc:a/network.cosmik.card/1")
        #expect(object["target"] as? String == "https://example.com/story")
    }

    @Test("Semble URL identity removes fragments and default ports")
    func normalizedURL() {
        #expect(SembleRecordService.normalizeURL(" HTTPS://Example.COM:443/story#comments ") == "https://example.com/story")
        #expect(SembleRecordService.normalizeURL("javascript:alert(1)") == nil)
    }

    @Test("Cache identity is viewer, provider, and collection scoped")
    func cacheIdentity() {
        let first = SocialWireAppModel.sembleCollectionCacheKey(
            viewerDID: "did:plc:one",
            collectionURI: "at://did:plc:one/network.cosmik.collection/a"
        )
        let second = SocialWireAppModel.sembleCollectionCacheKey(
            viewerDID: "did:plc:two",
            collectionURI: "at://did:plc:one/network.cosmik.collection/a"
        )
        #expect(first.contains("provider=semble"))
        #expect(first != second)
    }
}
