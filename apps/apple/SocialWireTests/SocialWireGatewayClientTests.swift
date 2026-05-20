import Testing
@testable import SocialWire

@Suite("SocialWireGatewayClient")
@MainActor
struct SocialWireGatewayClientTests {
    @Test("AppViewEnrollResponse decodes indexed count")
    func appViewEnrollResponseDecodesIndexedCount() throws {
        let data = Data("""
        {"indexed": 42}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewEnrollResponse.self, from: data)
        #expect(decoded.indexed == 42)
    }

    @Test("AppViewEntryListResponse decodes entries")
    func appViewEntryListResponseDecodesEntries() throws {
        let data = Data("""
        {"entries":[{"entryId":"at://did/site.standard.document/a","title":"A","publishedAt":"2026-01-01T00:00:00.000Z"}],"cursor":null}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewEntryListResponse.self, from: data)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].title == "A")
    }
}
