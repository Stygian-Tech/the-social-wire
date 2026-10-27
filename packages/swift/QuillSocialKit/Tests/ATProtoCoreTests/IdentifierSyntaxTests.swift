import Foundation
import Testing
@testable import ATProtoCore

@Suite struct IdentifierSyntaxTests {
    @Test(arguments: ["did:plc:z72i7hdynmk6r22z27h6tvur", "did:web:api.bsky.app", "did:web:localhost%3A1234"])
    func validDIDs(_ value: String) throws {
        #expect(try DID(value).rawValue == value)
    }

    @Test(arguments: ["did:PLC:abc", "did:plc:", "did:plc:abc:", "plc:abc", "did:plc:abc%"])
    func invalidDIDs(_ value: String) {
        #expect(throws: SyntaxError.invalidDID(value)) { try DID(value) }
    }

    @Test func didMethod() throws {
        #expect(try DID("did:web:api.bsky.app").method == "web")
    }

    @Test func handlesNormalizeToLowercase() throws {
        #expect(try Handle("Alice.BSKY.social").rawValue == "alice.bsky.social")
    }

    @Test(arguments: ["alice", "alice.bsky.social.", "-alice.bsky.social", "alice.123", "al ice.test"])
    func invalidHandles(_ value: String) {
        #expect(throws: SyntaxError.invalidHandle(value)) { try Handle(value) }
    }

    @Test func actorIdentifierAcceptsAtPrefixedHandles() throws {
        #expect(try ActorIdentifier("@bsky.app") == .handle(try Handle("bsky.app")))
        #expect(try ActorIdentifier("did:plc:z72i7hdynmk6r22z27h6tvur") == .did(try DID("did:plc:z72i7hdynmk6r22z27h6tvur")))
    }

    @Test func nsidParts() throws {
        let nsid = try NSID("app.bsky.feed.post")
        #expect(nsid.authority == "app.bsky.feed")
        #expect(nsid.name == "post")
    }

    @Test(arguments: ["app.bsky", "app.bsky.feed.post-thing", "1app.bsky.feed", "app..feed.post"])
    func invalidNSIDs(_ value: String) {
        #expect(throws: SyntaxError.invalidNSID(value)) { try NSID(value) }
    }

    @Test func atURIRoundTrip() throws {
        let value = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l3qo2vutsw2b"
        let uri = try ATURI(value)
        #expect(uri.collection == (try NSID("app.bsky.feed.post")))
        #expect(uri.recordKey == (try RecordKey("3l3qo2vutsw2b")))
        #expect(uri.description == value)
        let data = try JSONEncoder().encode(uri)
        #expect(try JSONDecoder().decode(ATURI.self, from: data) == uri)
    }

    @Test(arguments: ["https://bsky.app", "at://", "at://bsky.app//x", "at://bsky.app/a.b.c/k/extra"])
    func invalidATURIs(_ value: String) {
        #expect(throws: SyntaxError.invalidATURI(value)) { try ATURI(value) }
    }
}
