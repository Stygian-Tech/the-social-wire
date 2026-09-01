import Foundation
import Testing
@testable import SocialWire

@Suite("Editorial discovery contracts")
struct EditorialDiscoveryContractTests {
    @Test("Wire edition mirrors the XRPC editorial module contract")
    func wireEditionDecoding() throws {
        let data = Data(Self.wireEditionJSON.utf8)
        let edition = try JSONDecoder().decode(WireEditionPage.self, from: data)

        #expect(edition.editionVersion == "wire-v8")
        #expect(edition.generationId == "generation-1")
        #expect(edition.generatedAt == "2026-08-30T12:00:00.000Z")
        #expect(edition.source == .ranked)
        #expect(edition.stories.map(\.itemId) == ["story-1"])
        #expect(edition.stories[0].source.publicationKey == "example-publication")
        #expect(edition.stories[0].source.homepageUrl == "https://example.com")
        #expect(edition.stories[0].source.iconUrl == "https://example.com/icon.png")
        #expect(edition.topStoryIds == ["story-1"])
        #expect(edition.publicationSpotlights[0].storyIds == ["story-1", "story-2"])
        #expect(edition.storyRails[0].title == "Across Communities")
        #expect(edition.people[0].did == "did:plc:person")
        #expect(edition.trendingStoryIds == ["story-1"])
        #expect(edition.moreCursor == "next-page")
    }

    @Test("Circle catalog and edition mirror viewer-scoped XRPC contracts")
    func circleContractDecoding() throws {
        let catalog = try JSONDecoder().decode(
            CircleFeedCatalog.self,
            from: Data("""
            {
              "enabled": true,
              "available": true,
              "title": "Your Circle",
              "subtitle": "Stories moving through your network",
              "supportedLanguages": ["en", "fr"],
              "latestGenerationId": "viewer-generation-1",
              "generatedAt": "2026-08-30T12:00:00.000Z"
            }
            """.utf8)
        )
        #expect(catalog.isAvailable)
        #expect(catalog.supportedLanguages == ["en", "fr"])

        let edition = try JSONDecoder().decode(
            CircleEditionPage.self,
            from: Data(Self.circleEditionJSON.utf8)
        )
        #expect(edition.generationId == "viewer-generation-1")
        #expect(edition.source == .staleGeneration)
        #expect(edition.stories.count == 1)
        #expect(edition.stories[0].storyId == "circle-story-1")
        #expect(edition.stories[0].discussionCount == 3)
        #expect(edition.stories[0].sharerCount == 5)
        #expect(edition.stories[0].sharers.count == 5)
        #expect(edition.stories[0].sharers[0].relationship == "direct")
        #expect(edition.stories[0].sharers[1].relationship == "one_hop")
        #expect(edition.stories[0].sharers[0].action == "recommended")
        #expect(edition.publicationSpotlights[0].publication.publicationKey == "example-publication")
        #expect(edition.storyRails[0].storyIds == ["circle-story-1"])
        #expect(edition.trendingStoryIds == ["circle-story-1"])
        #expect(edition.moreCursor == "viewer-next-page")

        let hidden = try JSONDecoder().decode(
            CircleHiddenItemState.self,
            from: Data(#"{"storyId":"circle-story-1","hidden":true}"#.utf8)
        )
        #expect(hidden == CircleHiddenItemState(storyId: "circle-story-1", hidden: true))
    }

    @Test("Circle DTOs do not retain private graph or ranking fields")
    func circlePrivacyBoundary() throws {
        let decoded = try JSONDecoder().decode(
            CircleEditionPage.self,
            from: Data(Self.circleEditionJSON.utf8)
        )
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let stories = try #require(object["stories"] as? [[String: Any]])
        let story = try #require(stories.first)
        let sharers = try #require(story["sharers"] as? [[String: Any]])

        #expect(object["viewerHash"] == nil)
        #expect(story["rankingScore"] == nil)
        #expect(story["privateProvenance"] == nil)
        #expect(sharers[0]["relationshipWeight"] == nil)
    }

    @Test("Editorial routes, query keys, and DPoP proof boundaries match the Lexicons")
    func requestContracts() {
        #expect(SocialWireXRPCMethod.getWireEdition == "/xrpc/app.thesocialwire.discovery.getWireEdition")
        #expect(SocialWireXRPCMethod.getCircleCatalog == "/xrpc/app.thesocialwire.discovery.getCircleCatalog")
        #expect(SocialWireXRPCMethod.getCircleEdition == "/xrpc/app.thesocialwire.discovery.getCircleEdition")
        #expect(SocialWireXRPCMethod.setCircleItemHidden == "/xrpc/app.thesocialwire.discovery.setCircleItemHidden")

        #expect(SocialWireGatewayClient.wireEditionQuery(
            language: "pt",
            region: .outsideUnitedStates,
            cursor: "generation cursor"
        ) == [
            "lang": "pt",
            "region": "outside-us",
            "cursor": "generation cursor",
        ])
        var wireComponents = URLComponents(string: "https://api.example.test")
        wireComponents?.queryItems = SocialWireGatewayClient.wireEditionQuery(
            language: "pt",
            region: .outsideUnitedStates,
            cursor: "generation cursor"
        ).map { URLQueryItem(name: $0.key, value: $0.value) }
        #expect(wireComponents?.percentEncodedQuery?.contains("cursor=generation%20cursor") == true)
        #expect(SocialWireGatewayClient.circleEditionQuery(
            language: "en",
            cursor: "generation cursor"
        ) == ["lang": "en", "cursor": "generation cursor"])

        #expect(SocialWireGatewayClient.wireModerationDPoPHeader == "X-Wire-Moderation-DPoP")
        #expect(SocialWireGatewayClient.circleGraphDPoPHeader == "X-Circle-Graph-DPoP")
        #expect(SocialWireGatewayClient.requiresWireModerationProofs(
            path: SocialWireXRPCMethod.getWireEdition
        ))
        #expect(!SocialWireGatewayClient.requiresWireModerationProofs(
            path: SocialWireXRPCMethod.getCircleEdition
        ))
        #expect(SocialWireGatewayClient.requiresCircleGraphProofs(
            path: SocialWireXRPCMethod.getCircleEdition
        ))
        #expect(!SocialWireGatewayClient.requiresCircleGraphProofs(
            path: SocialWireXRPCMethod.getCircleCatalog
        ))
        #expect(!SocialWireGatewayClient.requiresCircleGraphProofs(
            path: SocialWireXRPCMethod.setCircleItemHidden
        ))
        #expect(SocialWireGatewayClient.circleViewerGraphNSIDs == [
            "app.bsky.actor.getPreferences",
            "app.bsky.graph.getBlocks",
            "app.bsky.graph.getMutes",
            "app.bsky.graph.getListMutes",
            "app.bsky.graph.getListBlocks",
            "com.atproto.repo.listRecords",
        ])
    }

    private static let wireEditionJSON = """
    {
      "editionVersion": "wire-v8",
      "generationId": "generation-1",
      "generatedAt": "2026-08-30T12:00:00.000Z",
      "language": "en",
      "source": "ranked",
      "degraded": false,
      "stories": [{
        "itemId": "story-1",
        "canonicalUrl": "https://example.com/story",
        "representativeUri": "at://did:plc:author/site.standard.document/story",
        "title": "A Story",
        "summary": "A summary",
        "publishedAt": "2026-08-30T11:00:00.000Z",
        "thumbnailUrl": "https://example.com/story.png",
        "source": {
          "name": "Example",
          "domain": "example.com",
          "publication": "at://did:plc:author/site.standard.publication/main",
          "publicationKey": "example-publication",
          "homepageUrl": "https://example.com",
          "iconUrl": "https://example.com/icon.png"
        },
        "reasons": ["widely_discussed"],
        "provenance": ["standard_site"]
      }],
      "topStoryIds": ["story-1"],
      "publicationSpotlights": [{
        "id": "example-publication",
        "publication": {"name":"Example","domain":"example.com","publicationKey":"example-publication"},
        "storyIds": ["story-1", "story-2"]
      }],
      "storyRails": [{"id":"across","title":"Across Communities","storyIds":["story-1"]}],
      "people": [{
        "did": "did:plc:person",
        "handle": "person.example.com",
        "displayName": "A Person",
        "avatarUrl": "https://example.com/avatar.png",
        "description": "Talked about today"
      }],
      "trendingStoryIds": ["story-1"],
      "moreCursor": "next-page"
    }
    """

    private static let circleEditionJSON = """
    {
      "editionVersion": "circle-v1",
      "generationId": "viewer-generation-1",
      "generatedAt": "2026-08-30T12:00:00.000Z",
      "language": "en",
      "source": "stale_generation",
      "degraded": false,
      "viewerHash": "must-not-survive",
      "stories": [{
        "storyId": "circle-story-1",
        "canonicalUrl": "https://example.com/circle-story",
        "representativeUri": "at://did:plc:author/site.standard.document/circle-story",
        "title": "A Circle Story",
        "summary": "A summary",
        "publishedAt": "2026-08-30T11:00:00.000Z",
        "thumbnailUrl": "https://example.com/circle-story.png",
        "source": {
          "name": "Example",
          "domain": "example.com",
          "publication": "at://did:plc:author/site.standard.publication/main",
          "publicationKey": "example-publication",
          "homepageUrl": "https://example.com",
          "iconUrl": "https://example.com/icon.png"
        },
        "reasons": ["shared_by_following", "popular_in_your_circle"],
        "discussionCount": 3,
        "sharerCount": 5,
        "rankingScore": 0.99,
        "privateProvenance": "margin",
        "sharers": [{
          "identity": {"did":"did:plc:direct","handle":"direct.example.com","displayName":"Direct"},
          "relationship": "direct",
          "action": "recommended",
          "sourceUri": "at://did:plc:direct/site.standard.recommendation/r1",
          "timestamp": "2026-08-30T11:30:00.000Z",
          "relationshipWeight": 1.0
        }, {
          "identity": {"did":"did:plc:hop","handle":"hop.example.com"},
          "relationship": "one_hop",
          "action": "discussed",
          "sourceUri": "at://did:plc:hop/app.bsky.feed.post/p1",
          "timestamp": "2026-08-30T11:20:00.000Z"
        }, {
          "identity": {"did":"did:plc:friend2","handle":"friend2.example.com","displayName":"Friend Two"},
          "relationship": "direct",
          "action": "shared",
          "sourceUri": "at://did:plc:friend2/app.bsky.feed.post/p2",
          "timestamp": "2026-08-30T11:10:00.000Z"
        }, {
          "identity": {"did":"did:plc:friend3","handle":"friend3.example.com","displayName":"Friend Three"},
          "relationship": "one_hop",
          "action": "shared",
          "sourceUri": "at://did:plc:friend3/app.bsky.feed.post/p3",
          "timestamp": "2026-08-30T11:00:00.000Z"
        }, {
          "identity": {"did":"did:plc:friend4","handle":"friend4.example.com","displayName":"Friend Four"},
          "relationship": "direct",
          "action": "shared",
          "sourceUri": "at://did:plc:friend4/app.bsky.feed.post/p4",
          "timestamp": "2026-08-30T10:50:00.000Z"
        }]
      }],
      "topStoryIds": ["circle-story-1"],
      "publicationSpotlights": [{
        "id": "example-publication",
        "publication": {"name":"Example","domain":"example.com","publicationKey":"example-publication"},
        "storyIds": ["circle-story-1", "circle-story-2"]
      }],
      "storyRails": [{"id":"network","title":"Across Your Circle","storyIds":["circle-story-1"]}],
      "trendingStoryIds": ["circle-story-1"],
      "moreCursor": "viewer-next-page"
    }
    """
}
