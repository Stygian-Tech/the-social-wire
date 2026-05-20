import Foundation

@MainActor
final class PublicationService {
    static let publicAppView = URL(string: "https://public.api.bsky.app")!
    static let publicationCollections = ["site.standard.publication", "com.standard.publication"]
    static let contentCollections = ["site.standard.document", "com.standard.document", "site.standard.entry", "com.standard.entry"]

    private let xrpc: XRPCClient

    init(xrpc: XRPCClient) {
        self.xrpc = xrpc
    }

    func discoverPublications(viewerDID: String) async throws -> [DiscoveredPublication] {
        var follows: [FollowProfile] = []
        var cursor: String?

        repeat {
            let page: FollowsResponse = try await xrpc.publicGet(
                Self.publicAppView,
                method: "app.bsky.graph.getFollows",
                query: ["actor": viewerDID, "limit": "100", "cursor": cursor]
            )
            follows.append(contentsOf: page.follows)
            cursor = page.cursor
        } while cursor != nil && follows.count < 500

        let candidates = [FollowProfile(did: viewerDID, handle: "You", displayName: "My Publications", avatar: nil)]
            + follows.prefix(500)
        var discovered: [DiscoveredPublication] = []

        for follow in candidates {
            let publications = await publicationRecords(for: follow)
            if !publications.isEmpty {
                discovered.append(contentsOf: publications)
                continue
            }
            if let content = await firstContentBackedPublication(for: follow) {
                discovered.append(content)
            }
        }

        return Array(Dictionary(grouping: discovered, by: \.publicationId).compactMap { $0.value.first })
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func listEntries(publicationId: String, limit: Int = 50) async throws -> [EntryListItem] {
        let (repoDid, publicationAtUri) = repoAndPublicationFilter(from: publicationId)
        var rows: [EntryListItem] = []
        for collection in Self.contentCollections {
            let page = try await xrpc.listGenericRecords(repo: repoDid, collection: collection, limit: limit, reverse: true)
            rows.append(contentsOf: page.records.compactMap { record in
                let parsed = EntryParser.parseListItem(record: record)
                guard publicationAtUri == nil || EntryParser.recordBelongsToPublication(record.value, publicationAtUri: publicationAtUri!) else {
                    return nil
                }
                return parsed
            })
        }
        return rows.sorted { $0.publishedAt > $1.publishedAt }
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

    /// All publication records on an author's repo (matches API `PublicationFollowDiscovery.discoverAuthor`).
    private func publicationRecords(for follow: FollowProfile) async -> [DiscoveredPublication] {
        var seen = Set<String>()
        var publications: [DiscoveredPublication] = []
        let discoveredAt = DateFormatters.string()
        let sidebarLabel: String = {
            let trimmed = follow.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? follow.handle : trimmed
        }()

        for collection in Self.publicationCollections {
            var cursor: String?
            repeat {
                guard let page = try? await xrpc.listGenericRecords(
                    repo: follow.did,
                    collection: collection,
                    limit: 50,
                    cursor: cursor,
                    reverse: false
                ) else { break }

                for record in page.records {
                    guard !seen.contains(record.uri) else { continue }
                    seen.insert(record.uri)
                    let value = record.value.object ?? [:]
                    let title = value["title"]?.string ?? value["name"]?.string ?? sidebarLabel
                    let icon = value["icon"]?.string ?? value["avatar"]?.string
                    publications.append(
                        DiscoveredPublication(
                            publicationId: record.uri,
                            subscriptionPublicationId: record.uri,
                            authorDid: follow.did,
                            authorHandle: follow.handle,
                            title: title,
                            iconUrl: icon,
                            avatarUrl: follow.avatar,
                            discoveredAt: discoveredAt
                        )
                    )
                }
                cursor = page.cursor
            } while cursor != nil
        }
        return publications
    }

    private func firstContentBackedPublication(for follow: FollowProfile) async -> DiscoveredPublication? {
        for collection in Self.contentCollections {
            guard let page = try? await xrpc.listGenericRecords(repo: follow.did, collection: collection, limit: 1),
                  !page.records.isEmpty
            else { continue }
            return DiscoveredPublication(
                publicationId: follow.did,
                authorDid: follow.did,
                authorHandle: follow.handle,
                title: follow.displayName ?? follow.handle,
                iconUrl: follow.avatar,
                avatarUrl: follow.avatar,
                discoveredAt: DateFormatters.string()
            )
        }
        return nil
    }
}
