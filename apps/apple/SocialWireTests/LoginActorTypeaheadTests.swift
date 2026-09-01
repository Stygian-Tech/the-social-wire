import Testing
@testable import SocialWire

@Suite("Login actor typeahead")
struct LoginActorTypeaheadTests {
    @Test("normalizes handles and rejects the same invalid queries as web")
    func queryValidation() {
        #expect(ATProtoResolver.loginHandleSearchQuery(" @alice.bsky.social ") == "alice.bsky.social")
        #expect(ATProtoResolver.loginHandleSearchQuery("alice") == "alice")
        #expect(ATProtoResolver.loginHandleSearchQuery("a") == nil)
        #expect(ATProtoResolver.loginHandleSearchQuery("did:plc:alice") == nil)
        #expect(ATProtoResolver.loginHandleSearchQuery("https://alice.example") == nil)
        #expect(ATProtoResolver.loginHandleSearchQuery("alice smith") == nil)
    }
}
