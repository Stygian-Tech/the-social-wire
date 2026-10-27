import Testing
@testable import Feeds

@Suite("Post Share URL")
struct PostShareURLTests {
    @Test("A post record becomes a portable HTTPS link")
    func webLink() {
        #expect(PostShareURL.url(for: "at://did:plc:alice/app.bsky.feed.post/3key")?.absoluteString == "https://bsky.app/profile/did:plc:alice/post/3key")
        #expect(PostShareURL.url(for: "at://alice.test/app.bsky.feed.post/3key")?.absoluteString == "https://bsky.app/profile/alice.test/post/3key")
    }

    @Test("Nonpost, incomplete and malformed references are rejected", arguments: [
        "https://example.com", "at://did:plc:alice", "at://did:plc:alice/app.bsky.feed.post",
        "at://did:plc:alice/app.bsky.feed.like/key", "at://did:plc:alice/app.bsky.feed.post/key?x=y",
        "at://did:plc:alice/app.bsky.feed.post/key#fragment", "at:///app.bsky.feed.post/key"
    ])
    func rejectsInvalid(uri: String) {
        #expect(PostShareURL.url(for: uri) == nil)
    }
}
