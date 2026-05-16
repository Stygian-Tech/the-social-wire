import XCTest
@testable import SocialWire

final class SocialWireUtilityTests: XCTestCase {
    func testATURIParsing() {
        let uri = ATURI("at://did:plc:alice/site.standard.document/abc123")
        XCTAssertEqual(uri?.repo, "did:plc:alice")
        XCTAssertEqual(uri?.collection, "site.standard.document")
        XCTAssertEqual(uri?.rkey, "abc123")
    }

    func testReadStateRKeyIsDeterministicBase32() {
        let first = DeterministicKeys.entryReadStateRKey(subjectURI: "at://did:plc:alice/site.standard.document/abc123")
        let second = DeterministicKeys.entryReadStateRKey(subjectURI: "at://did:plc:alice/site.standard.document/abc123")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 52)
        XCTAssertTrue(first.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
    }

    func testPublicURLNormalizerPromotesHTTPAndStripsBridgeNoise() {
        let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS("http://example.com/post?bridge_completed=1&x=2")
        XCTAssertEqual(normalized, "https://example.com/post?x=2")
    }

    func testLatrMergeDropsArchivedAndPairsExternalRows() {
        let external = RepoRecord(
            uri: "at://did:plc:me/com.latr.saved.external/ext",
            cid: nil,
            value: LatrSavedExternalRecord(
                type: PDSRecordService.latrSavedExternal,
                url: "https://example.com",
                normalizedUrl: "https://example.com",
                fingerprint: "abc",
                createdAt: "2026-05-16T00:00:00.000Z",
                title: "Example"
            )
        )
        let item = RepoRecord(
            uri: "at://did:plc:me/com.latr.saved.item/item",
            cid: nil,
            value: LatrSavedItemRecord(
                type: PDSRecordService.latrSavedItem,
                subjectUri: "at://did:plc:me/com.latr.saved.external/ext",
                savedAt: "2026-05-16T01:00:00.000Z",
                state: "unread"
            )
        )

        let rows = PDSRecordService.merge(externals: [external], items: [item])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "Example")
    }

    func testHTMLWrapperContainsCSP() {
        let wrapped = HTMLRenderer.wrappedHTML("<p>Hello</p>")
        XCTAssertTrue(wrapped.contains("Content-Security-Policy"))
        XCTAssertTrue(wrapped.contains("<p>Hello</p>"))
    }
}
