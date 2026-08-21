import Foundation
import SwiftData
import Testing
@testable import SocialWire

@Suite("The Wire feed")
struct WireFeedTests {
    @Test("catalog availability requires enabled and available")
    func catalogAvailability() {
        let enabled = WireFeedCatalog(
            enabled: true,
            available: true,
            title: "The Wire",
            subtitle: "Important stories across the social web",
            supportedLanguages: ["en"],
            latestGenerationId: "g1",
            generatedAt: nil
        )
        #expect(enabled.isAvailable)
        let unavailable = WireFeedCatalog(
            enabled: true,
            available: false,
            title: "The Wire",
            subtitle: "Important stories across the social web",
            supportedLanguages: ["en"],
            latestGenerationId: nil,
            generatedAt: nil
        )
        #expect(!unavailable.isAvailable)
    }

    @Test("page decodes bounded reasons and source metadata")
    func pageDecoding() throws {
        let data = Data("""
        {
          "generationId":"g1",
          "generatedAt":"2026-08-20T12:00:00Z",
          "language":"en",
          "cursor":"opaque",
          "source":"stale_generation",
          "degraded":true,
          "items":[{
            "itemId":"story-1",
            "canonicalUrl":"https://example.com/story",
            "representativeUri":"at://did:plc:author/site.standard.document/story",
            "title":"Story",
            "summary":"Summary",
            "publishedAt":"2026-08-20T11:00:00Z",
            "source":{"name":"Example","domain":"example.com"},
            "reasons":["widely_discussed","shared_across_communities","ignored"],
            "provenance":["at://did:plc:author/site.standard.document/story"]
          }]
        }
        """.utf8)
        let page = try JSONDecoder().decode(WireFeedPage.self, from: data)
        #expect(page.cursor == "opaque")
        #expect(page.notice == "Showing a recently generated edition.")
        #expect(page.items[0].reasons.count == 2)
        let entry = page.items[0].toEntryListItem()
        #expect(entry.id == "story-1")
        #expect(entry.wireMetadata?.source.displayName == "Example")
        #expect(entry.wireMetadata?.primaryReasonLabel == "Widely Discussed")
        #expect(entry.wireMetadata?.reasonLabels == ["Widely Discussed", "Shared Across Communities"])
        #expect(!entry.isRead)
    }

    @Test("flat and enveloped item details both decode")
    func tolerantItemDetailDecoding() throws {
        let flatItem = """
        {"itemId":"story-1","canonicalUrl":"https://example.com/story","title":"Story","source":{"name":"Example","domain":"example.com"},"reasons":[],"provenance":[],"html":"<p>Flat body</p>"}
        """
        let envelopeItem = """
        {"itemId":"story-1","canonicalUrl":"https://example.com/story","title":"Story","summary":"Summary","source":{"name":"Example","domain":"example.com"},"reasons":[],"provenance":[]}
        """
        let flat = try JSONDecoder().decode(WireFeedItemResponse.self, from: Data(flatItem.utf8))
        let enveloped = try JSONDecoder().decode(
            WireFeedItemResponse.self,
            from: Data("{\"item\":\(envelopeItem),\"html\":\"<p>Envelope body</p>\",\"embedUrl\":\"http://example.com/embed\"}".utf8)
        )
        #expect(flat.item.itemId == enveloped.item.itemId)
        #expect(flat.toEntryDetail().contentHtml == "<p>Flat body</p>")
        #expect(enveloped.toEntryDetail().contentHtml == "<p>Envelope body</p>")
        #expect(enveloped.toEntryDetail().embedUrl == "https://example.com/embed")
        #expect(enveloped.toEntryDetail().bskyPostUri == nil)
    }

    @Test("viewer moderation proof order matches the gateway contract")
    func viewerModerationProofOrder() {
        #expect(SocialWireGatewayClient.wireViewerModerationNSIDs == [
            "app.bsky.actor.getPreferences",
            "app.bsky.graph.getBlocks",
            "app.bsky.graph.getMutes",
            "app.bsky.graph.getListMutes",
            "app.bsky.graph.getListBlocks",
        ])
    }

    @Test("The Wire requests use the lexicon language key and moderation proofs")
    func wireRequestContract() {
        #expect(SocialWireGatewayClient.wireQuery(
            language: "fr",
            cursor: "next",
            limit: 25
        ) == [
            "lang": "fr",
            "cursor": "next",
            "limit": "25",
        ])
        #expect(SocialWireGatewayClient.requiresWireModerationProofs(
            path: SocialWireXRPCMethod.getWire
        ))
        #expect(SocialWireGatewayClient.requiresWireModerationProofs(
            path: SocialWireXRPCMethod.getWireItem
        ))
        #expect(!SocialWireGatewayClient.requiresWireModerationProofs(
            path: SocialWireXRPCMethod.getFeedCatalog
        ))
    }
}

@MainActor
@Suite("The Wire cache")
struct WireFeedCacheTests {
    @Test("page and detail caches remain viewer scoped and independent from publication caches")
    func cacheRoundTrip() throws {
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let coordinator = ReaderCacheCoordinator(modelContext: ModelContext(container))
        let page = WireFeedPage(
            generationId: "g1",
            generatedAt: "2026-08-20T12:00:00Z",
            language: "en",
            cursor: "next",
            source: "ranked",
            degraded: false,
            items: []
        )
        try coordinator.upsertWireFeedPage(page, viewerDID: "did:plc:alice")
        #expect(try coordinator.wireFeedPage(
            viewerDID: "did:plc:alice",
            language: "en"
        ) == page)
        #expect(try coordinator.wireFeedPage(
            viewerDID: "did:plc:bob",
            language: "en"
        ) == nil)

        let nextViewerPage = WireFeedPage(
            generationId: "g2",
            generatedAt: "2026-08-20T12:05:00Z",
            language: "en",
            cursor: nil,
            source: "ranked",
            degraded: false,
            items: []
        )
        try coordinator.upsertWireFeedPage(nextViewerPage, viewerDID: "did:plc:bob")
        #expect(try coordinator.wireFeedPage(
            viewerDID: "did:plc:alice",
            language: "en"
        ) == nil)
        #expect(try coordinator.wireFeedPage(
            viewerDID: "did:plc:bob",
            language: "en"
        ) == nextViewerPage)

        let detail = EntryDetail(
            entryId: "story-1",
            title: "Story",
            publishedAt: "",
            contentHtml: "<p>Body</p>",
            originalUrl: "https://example.com/story",
            embedUrl: "https://example.com/story",
            bskyPostUri: nil,
            bskyPostCid: nil
        )
        try coordinator.upsertWireItemDetail(detail, viewerDID: "did:plc:alice")
        #expect(try coordinator.wireItemDetail(
            itemId: detail.entryId,
            viewerDID: "did:plc:alice"
        ) == detail)
        #expect(try coordinator.wireItemDetail(
            itemId: detail.entryId,
            viewerDID: "did:plc:bob"
        ) == nil)
        #expect(try coordinator.publicationEntries("wire") == nil)
    }
}
