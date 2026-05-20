import Testing
@testable import SocialWire

@Suite("SocialWire utilities")
struct SocialWireUtilityTests {
    @Test("AT URI parsing")
    func aturiParsing() {
        let uri = ATURI("at://did:plc:alice/site.standard.document/abc123")
        #expect(uri?.repo == "did:plc:alice")
        #expect(uri?.collection == "site.standard.document")
        #expect(uri?.rkey == "abc123")
    }

    @Test("read-state rkey is deterministic base32")
    func readStateRKeyIsDeterministicBase32() {
        let first = DeterministicKeys.entryReadStateRKey(subjectURI: "at://did:plc:alice/site.standard.document/abc123")
        let second = DeterministicKeys.entryReadStateRKey(subjectURI: "at://did:plc:alice/site.standard.document/abc123")
        #expect(first == second)
        #expect(first.count == 52)
        #expect(first.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
    }

    @Test("PublicURLNormalizer promotes HTTP and strips bridge noise")
    func publicURLNormalizerPromotesHTTPAndStripsBridgeNoise() {
        let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS("http://example.com/post?bridge_completed=1&x=2")
        #expect(normalized == "https://example.com/post?x=2")
    }

    @Test("L@tr merge drops archived and pairs external rows")
    func latrMergeDropsArchivedAndPairsExternalRows() {
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
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Example")
    }

    @Test("HTML wrapper contains CSP")
    func htmlWrapperContainsCSP() {
        let wrapped = HTMLRenderer.wrappedHTML("<p>Hello</p>")
        #expect(wrapped.contains("Content-Security-Policy"))
        #expect(wrapped.contains("<p>Hello</p>"))
    }
}
