import Foundation
import SwiftData
import Testing
@testable import SocialWire

@Suite("ReaderCacheCoordinator")
@MainActor
struct ReaderCacheCoordinatorTests {
    @Test("unread cached counts respect read states")
    func unreadCachedCountsRespectReadStates() throws {
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let context = ModelContext(container)
        let coord = ReaderCacheCoordinator(modelContext: context)

        let items = [
            EntryListItem(
                entryId: "a",
                title: "A",
                summary: nil,
                publishedAt: "2026-05-01T00:00:00.000Z",
                thumbnailUrl: nil,
                thumbnailFallbackUrl: nil
            ),
            EntryListItem(
                entryId: "b",
                title: "B",
                summary: nil,
                publishedAt: "2026-05-02T00:00:00.000Z",
                thumbnailUrl: nil,
                thumbnailFallbackUrl: nil
            ),
        ]
        try coord.upsertPublicationEntries(publicationId: "pub1", entries: items)

        let readMap: [String: Date] = ["a": Date()]
        #expect(coord.unreadCachedCount(publicationId: "pub1", readAtByEntryId: readMap) == 1)
        #expect(coord.unreadCachedCount(publicationId: "pub1", readAtByEntryId: [:]) == 2)
    }

    @Test("distinct cached entry IDs dedupe across publications")
    func distinctCachedEntryIdsDedupesAcrossPublications() throws {
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let context = ModelContext(container)
        let coord = ReaderCacheCoordinator(modelContext: context)

        let sharedId = "at://example/app.bsky.feed.post/shared"
        try coord.upsertPublicationEntries(
            publicationId: "pub-a",
            entries: [
                EntryListItem(
                    entryId: sharedId,
                    title: "Shared",
                    summary: nil,
                    publishedAt: "2026-05-01T00:00:00.000Z",
                    thumbnailUrl: nil,
                    thumbnailFallbackUrl: nil
                ),
                EntryListItem(
                    entryId: "only-a",
                    title: "A",
                    summary: nil,
                    publishedAt: "2026-05-02T00:00:00.000Z",
                    thumbnailUrl: nil,
                    thumbnailFallbackUrl: nil
                ),
            ]
        )
        try coord.upsertPublicationEntries(
            publicationId: "pub-b",
            entries: [
                EntryListItem(
                    entryId: sharedId,
                    title: "Shared",
                    summary: nil,
                    publishedAt: "2026-05-01T00:00:00.000Z",
                    thumbnailUrl: nil,
                    thumbnailFallbackUrl: nil
                ),
                EntryListItem(
                    entryId: "only-b",
                    title: "B",
                    summary: nil,
                    publishedAt: "2026-05-03T00:00:00.000Z",
                    thumbnailUrl: nil,
                    thumbnailFallbackUrl: nil
                ),
            ]
        )

        let ids = coord.distinctCachedEntryIds(publicationIds: ["pub-a", "pub-b"])
        #expect(Set(ids) == Set([sharedId, "only-a", "only-b"]))
        #expect(ids.count == 3)
    }

    @Test("gateway ETag round-trip through upsert")
    func gatewayETagRoundTripThroughUpsert() throws {
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let context = ModelContext(container)
        let coord = ReaderCacheCoordinator(modelContext: context)

        try coord.upsertGatewayResponse(cacheKey: " GET /preferences ", etag: "\"v1\"", body: Data([0xDE, 0xAD]))
        #expect(coord.gatewayETag(for: "GET /preferences") == "\"v1\"")
        #expect(coord.gatewayCachedBody(for: "GET /preferences") == Data([0xDE, 0xAD]))
    }

    @Test("editorial editions are isolated by viewer and language")
    func editorialEditionsAreViewerScoped() throws {
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let coord = ReaderCacheCoordinator(modelContext: ModelContext(container))
        let wireA = Self.wireEdition(generationId: "wire-a")
        let wireB = Self.wireEdition(generationId: "wire-b")
        let circleA = Self.circleEdition(generationId: "circle-a")
        let circleB = Self.circleEdition(generationId: "circle-b")

        try coord.upsertWireEditionPage(wireA, viewerDID: "did:plc:a", language: " EN ")
        try coord.upsertWireEditionPage(wireB, viewerDID: "did:plc:b", language: "en")
        try coord.upsertCircleEditionPage(circleA, viewerDID: "did:plc:a", language: "EN")
        try coord.upsertCircleEditionPage(circleB, viewerDID: "did:plc:b", language: "en")

        #expect(try coord.wireEditionPage(viewerDID: "did:plc:a", language: "en") == wireA)
        #expect(try coord.wireEditionPage(viewerDID: "did:plc:b", language: "EN") == wireB)
        #expect(try coord.wireEditionPage(viewerDID: "did:plc:c", language: "en") == nil)
        #expect(try coord.circleEditionPage(viewerDID: "did:plc:a", language: "en") == circleA)
        #expect(try coord.circleEditionPage(viewerDID: "did:plc:b", language: "EN") == circleB)
        #expect(try coord.circleEditionPage(viewerDID: "did:plc:c", language: "en") == nil)
    }

    @Test("Circle logout cleanup removes only the signed-out viewer")
    func circleCleanupIsViewerScoped() throws {
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let coord = ReaderCacheCoordinator(modelContext: ModelContext(container))
        let wire = Self.wireEdition(generationId: "wire-a")
        let circleA = Self.circleEdition(generationId: "circle-a")
        let circleB = Self.circleEdition(generationId: "circle-b")
        let detailA = Self.entryDetail(id: "story-a")
        let detailB = Self.entryDetail(id: "story-b")

        try coord.upsertWireEditionPage(wire, viewerDID: "did:plc:a", language: "en")
        try coord.upsertCircleEditionPage(circleA, viewerDID: "did:plc:a", language: "en")
        try coord.upsertCircleEditionPage(circleB, viewerDID: "did:plc:b", language: "en")
        try coord.upsertCircleItemDetail(detailA, storyId: "story-a", viewerDID: "did:plc:a")
        try coord.upsertCircleItemDetail(detailB, storyId: "story-b", viewerDID: "did:plc:b")

        try coord.clearCircleDiscoveryCache(viewerDID: "did:plc:a")

        #expect(try coord.circleEditionPage(viewerDID: "did:plc:a", language: "en") == nil)
        #expect(try coord.circleItemDetail(storyId: detailA.entryId, viewerDID: "did:plc:a") == nil)
        #expect(try coord.circleEditionPage(viewerDID: "did:plc:b", language: "en") == circleB)
        #expect(try coord.circleItemDetail(storyId: detailB.entryId, viewerDID: "did:plc:b") == detailB)
        #expect(try coord.wireEditionPage(viewerDID: "did:plc:a", language: "en") == wire)
    }

    private static func wireEdition(generationId: String) -> WireEditionPage {
        WireEditionPage(
            editionVersion: "1",
            generationId: generationId,
            generatedAt: "2026-08-30T12:00:00Z",
            language: "en",
            source: .ranked,
            degraded: false,
            stories: [],
            topStoryIds: [],
            publicationSpotlights: [],
            storyRails: [],
            people: [],
            trendingStoryIds: [],
            moreCursor: nil
        )
    }

    private static func circleEdition(generationId: String) -> CircleEditionPage {
        CircleEditionPage(
            editionVersion: "1",
            generationId: generationId,
            generatedAt: "2026-08-30T12:00:00Z",
            language: "en",
            source: .ranked,
            degraded: false,
            stories: [],
            topStoryIds: [],
            publicationSpotlights: [],
            storyRails: [],
            trendingStoryIds: [],
            moreCursor: nil
        )
    }

    private static func entryDetail(id: String) -> EntryDetail {
        EntryDetail(
            entryId: id,
            title: id,
            publishedAt: "2026-08-30T12:00:00Z",
            contentHtml: "<p>Cached</p>",
            originalUrl: "https://example.com/\(id)",
            embedUrl: "https://example.com/\(id)",
            bskyPostUri: nil,
            bskyPostCid: nil
        )
    }
}
