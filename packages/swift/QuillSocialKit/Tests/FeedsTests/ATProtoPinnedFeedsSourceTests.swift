import ATProtoCore
import Feeds
import Foundation
import Testing

struct ATProtoPinnedFeedsSourceTests {
    @Test func publicGeneratorRecordResolvesNamesWhenSessionLacksAppViewScope() async throws {
        let values = ["for-you", "whats-hot"].map { "at://did:plc:test/app.bsky.feed.generator/\($0)" }
        let preferences = try JSONSerialization.data(withJSONObject: ["preferences": [[
            "$type": "app.bsky.actor.defs#savedFeedsPref", "pinned": values,
        ]]])
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { preferences },
            feedRequest: { _ in throw URLError(.userAuthenticationRequired) },
            generatorRecordRequest: { uri in
                let name = uri.hasSuffix("for-you") ? "For You ✨" : "Discover"
                return try JSONSerialization.data(withJSONObject: [
                    "uri": uri, "value": ["$type": "app.bsky.feed.generator", "displayName": name],
                ])
            }
        )

        let feeds = try await source.pinnedFeeds()

        #expect(feeds.map(\.name) == ["For You ✨", "Discover"])
        #expect(feeds.map { $0.uri.description } == values)
    }

    @Test func resolvedAppViewMetadataDoesNotNeedPublicRecordLookup() async throws {
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { Data(#"{"preferences":[{"$type":"app.bsky.actor.defs#savedFeedsPref","pinned":["at://did:plc:test/app.bsky.feed.generator/fu"]}]}"#.utf8) },
            feedRequest: { _ in Data(#"{"view":{"displayName":"Friends","avatar":"https://example.test/feed.png"}}"#.utf8) },
            generatorRecordRequest: { _ in
                Issue.record("Resolved App View metadata should not trigger a public record lookup")
                throw URLError(.badServerResponse)
            }
        )

        let feed = try #require(try await source.pinnedFeeds().first)

        #expect(feed.name == "Friends")
        #expect(feed.avatarURL?.absoluteString == "https://example.test/feed.png")
    }

    @Test func failedMetadataLookupsKeepFeedAvailable() async throws {
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { Data(#"{"preferences":[{"$type":"app.bsky.actor.defs#savedFeedsPref","pinned":["at://did:plc:test/app.bsky.feed.generator/fu"]}]}"#.utf8) },
            feedRequest: { _ in throw URLError(.cannotConnectToHost) },
            generatorRecordRequest: { _ in throw URLError(.cannotFindHost) }
        )

        let feeds = try await source.pinnedFeeds()

        #expect(feeds.map(\.name) == ["fu"])
        #expect(feeds.first?.uri.description == "at://did:plc:test/app.bsky.feed.generator/fu")
    }

    private actor BodyCapture {
        private var body: Data?

        func store(_ body: Data) {
            self.body = body
        }

        func value() -> Data? {
            body
        }
    }

    @Test func savedFeedsV2ReturnsPinnedGeneratorsInAccountOrder() async throws {
        let preferences = Data(#"""
            {
                "preferences": [{
                    "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
                    "items": [
                        {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/first","pinned":true},
                        {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/hidden","pinned":false},
                        {"type":"list","value":"at://did:plc:test/app.bsky.graph.list/friends","pinned":true},
                        {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/second","pinned":true}
                    ]
                }]
            }
            """#.utf8)
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { preferences },
            feedRequest: { uri in
                let name = uri.hasSuffix("first") ? "First Feed" : "Second Feed"
                return Data("{\"view\":{\"displayName\":\"\(name)\"}}".utf8)
            }
        )

        let feeds = try await source.pinnedFeeds()

        #expect(feeds.map(\.name) == ["First Feed", "Second Feed"])
        #expect(feeds.map { $0.uri.description }.map { $0.split(separator: "/").last } == ["first", "second"])
    }

    @Test func legacySavedFeedsAreSupported() async throws {
        let preferences = Data(#"""
            {
                "preferences": [{
                    "$type": "app.bsky.actor.defs#savedFeedsPref",
                    "pinned": ["at://did:plc:test/app.bsky.feed.generator/legacy"]
                }]
            }
            """#.utf8)
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { preferences },
            feedRequest: { _ in Data(#"{"view":{"displayName":"Legacy"}}"#.utf8) }
        )

        let feeds = try await source.pinnedFeeds()

        #expect(feeds.map(\.name) == ["Legacy"])
    }

    @Test func currentPreferenceOrderWinsOverLegacyPreference() async throws {
        let preferences = Data(#"""
            {
                "preferences": [
                    {
                        "$type": "app.bsky.actor.defs#savedFeedsPref",
                        "pinned": ["at://did:plc:test/app.bsky.feed.generator/legacy"]
                    },
                    {
                        "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
                        "items": [
                            {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/second","pinned":true},
                            {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/first","pinned":true}
                        ]
                    }
                ]
            }
            """#.utf8)
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { preferences },
            feedRequest: { uri in
                let name = uri.hasSuffix("first") ? "First Feed" : "Second Feed"
                return Data("{\"view\":{\"displayName\":\"\(name)\"}}".utf8)
            }
        )

        let feeds = try await source.pinnedFeeds()

        #expect(feeds.map(\.name) == ["Second Feed", "First Feed"])
    }

    @Test func updatingFeedsPersistsOrderAndRemovalWithoutDroppingOtherItems() async throws {
        let preferences = Data(#"""
            {
                "preferences": [{
                    "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
                    "items": [
                        {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/first","pinned":true},
                        {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/hidden","pinned":false},
                        {"type":"list","value":"at://did:plc:test/app.bsky.graph.list/friends","pinned":true},
                        {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/second","pinned":true},
                        {"type":"feed","value":"at://did:plc:test/app.bsky.feed.generator/third","pinned":true}
                    ]
                }]
            }
            """#.utf8)
        let capture = BodyCapture()
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { preferences },
            preferencesUpdate: { body in await capture.store(body) },
            feedRequest: { _ in Data() }
        )
        let third = PinnedFeed(
            uri: try ATURI("at://did:plc:test/app.bsky.feed.generator/third"),
            name: "Third"
        )
        let first = PinnedFeed(
            uri: try ATURI("at://did:plc:test/app.bsky.feed.generator/first"),
            name: "First"
        )

        try await source.updatePinnedFeeds([third, first])

        let body = try #require(await capture.value())
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let savedPreference = try #require((object["preferences"] as? [[String: Any]])?.first)
        let items = try #require(savedPreference["items"] as? [[String: Any]])
        let pinnedFeeds = items.filter {
            $0["type"] as? String == "feed" && $0["pinned"] as? Bool == true
        }
        #expect(pinnedFeeds.compactMap { $0["value"] as? String }.map { $0.split(separator: "/").last } == ["third", "first"])
        #expect(items.contains { $0["value"] as? String == "at://did:plc:test/app.bsky.feed.generator/hidden" })
        #expect(items.contains { $0["type"] as? String == "list" })
    }
}
