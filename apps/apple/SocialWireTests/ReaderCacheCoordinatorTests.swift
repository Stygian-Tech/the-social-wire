import SwiftData
import XCTest
@testable import SocialWire

@MainActor
final class ReaderCacheCoordinatorTests: XCTestCase {

    func testUnreadCachedCountsRespectReadStates() throws {
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
        XCTAssertEqual(coord.unreadCachedCount(publicationId: "pub1", readAtByEntryId: readMap), 1)
        XCTAssertEqual(coord.unreadCachedCount(publicationId: "pub1", readAtByEntryId: [:]), 2)
    }

    func testGatewayETagRoundTripThroughUpsert() throws {
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let context = ModelContext(container)
        let coord = ReaderCacheCoordinator(modelContext: context)

        try coord.upsertGatewayResponse(cacheKey: " GET /preferences ", etag: "\"v1\"", body: Data([0xDE, 0xAD]))
        XCTAssertEqual(coord.gatewayETag(for: "GET /preferences"), "\"v1\"")
        XCTAssertEqual(coord.gatewayCachedBody(for: "GET /preferences"), Data([0xDE, 0xAD]))
    }
}
