import Foundation

@MainActor
final class PublicationService {
    static let publicAppView = URL(string: "https://public.api.bsky.app")!
    private let xrpc: XRPCClient

    init(xrpc: XRPCClient) {
        self.xrpc = xrpc
    }

    func entryDetail(entryId: String) async throws -> EntryDetail {
        guard let at = ATURI(entryId) else { throw SocialWireError.invalidATURI }
        let record = try await xrpc.getGenericRecord(repo: at.repo, collection: at.collection, rkey: at.rkey)
        return EntryParser.parseDetail(record: record)
    }

    func fetchActorProfile(actor: String) async throws -> ActorProfileResponse {
        try await xrpc.publicGet(
            Self.publicAppView,
            method: "app.bsky.actor.getProfile",
            query: ["actor": actor]
        )
    }

    func viewerState(for postURI: String) async throws -> ProfileViewResponse.Viewer? {
        let response: PostsResponse = try await xrpc.publicGet(
            Self.publicAppView,
            method: "app.bsky.feed.getPosts",
            query: ["uris": postURI]
        )
        return response.posts.first?.viewer
    }

    func createQuote(text: String, entry: EntryDetail) async throws {
        let now = DateFormatters.string()
        var record: [String: JSONValue] = [
            "$type": .string("app.bsky.feed.post"),
            "text": .string(text),
            "createdAt": .string(now)
        ]
        if let uri = entry.bskyPostUri, let cid = entry.bskyPostCid {
            record["embed"] = .object([
                "$type": .string("app.bsky.embed.record"),
                "record": .object(["uri": .string(uri), "cid": .string(cid)])
            ])
        } else if let url = entry.canonicalURL?.absoluteString {
            record["embed"] = .object([
                "$type": .string("app.bsky.embed.external"),
                "external": .object([
                    "uri": .string(url),
                    "title": .string(entry.title),
                    "description": .string("")
                ])
            ])
        }
        try await xrpc.putRecord(collection: "app.bsky.feed.post", rkey: DeterministicKeys.generateTID(), record: record)
    }

    func createLike(entry: EntryDetail) async throws {
        guard let uri = entry.bskyPostUri, let cid = entry.bskyPostCid else { throw SocialWireError.unsupported }
        let record: [String: JSONValue] = [
            "$type": .string("app.bsky.feed.like"),
            "subject": .object(["uri": .string(uri), "cid": .string(cid)]),
            "createdAt": .string(DateFormatters.string())
        ]
        try await xrpc.createRecord(collection: "app.bsky.feed.like", record: record)
    }

    func createRepost(entry: EntryDetail) async throws {
        guard let uri = entry.bskyPostUri, let cid = entry.bskyPostCid else { throw SocialWireError.unsupported }
        let record: [String: JSONValue] = [
            "$type": .string("app.bsky.feed.repost"),
            "subject": .object(["uri": .string(uri), "cid": .string(cid)]),
            "createdAt": .string(DateFormatters.string())
        ]
        try await xrpc.createRecord(collection: "app.bsky.feed.repost", record: record)
    }

    func createReply(text: String, entry: EntryDetail) async throws {
        guard let uri = entry.bskyPostUri, let cid = entry.bskyPostCid else { throw SocialWireError.unsupported }
        let subject: [String: JSONValue] = [
            "uri": .string(uri),
            "cid": .string(cid),
        ]
        let record: [String: JSONValue] = [
            "$type": .string("app.bsky.feed.post"),
            "text": .string(text),
            "createdAt": .string(DateFormatters.string()),
            "reply": .object([
                "root": .object(subject),
                "parent": .object(subject),
            ]),
        ]
        try await xrpc.putRecord(collection: "app.bsky.feed.post", rkey: DeterministicKeys.generateTID(), record: record)
    }
}
