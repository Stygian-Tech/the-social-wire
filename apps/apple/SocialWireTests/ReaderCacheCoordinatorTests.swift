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
}
