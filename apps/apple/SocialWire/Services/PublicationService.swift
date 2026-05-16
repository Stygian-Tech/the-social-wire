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

        let candidates = [FollowProfile(did: viewerDID, handle: "You", displayName: "My Publications", avatar: nil)] + follows.prefix(500)
        var discovered: [DiscoveredPublication] = []

        for follow in candidates {
            if let publication = await firstPublicationRecord(for: follow, viewerDID: viewerDID) {
                discovered.append(publication)
                continue
            }
            if let content = await firstContentBackedPublication(for: follow, viewerDID: viewerDID) {
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

    private func firstPublicationRecord(for follow: FollowProfile, viewerDID: String) async -> DiscoveredPublication? {
        for collection in Self.publicationCollections {
            guard let page = try? await xrpc.listGenericRecords(repo: follow.did, collection: collection, limit: 10),
                  let record = page.records.first
            else { continue }

            let value = record.value.object ?? [:]
            let title = value["title"]?.string ?? value["name"]?.string ?? follow.displayName ?? follow.handle
            let icon = value["icon"]?.string ?? value["avatar"]?.string
            return DiscoveredPublication(
                publicationId: record.uri,
                subscriptionPublicationId: record.uri,
                authorDid: follow.did,
                authorHandle: follow.handle,
                title: title,
                iconUrl: icon,
                avatarUrl: follow.avatar,
                discoveredAt: DateFormatters.string()
            )
        }
        return nil
    }

    private func firstContentBackedPublication(for follow: FollowProfile, viewerDID: String) async -> DiscoveredPublication? {
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

enum EntryParser {
    static func parseListItem(record: GenericRepoRecord) -> EntryListItem {
        let value = record.value.object ?? [:]
        let title = firstString(value, keys: ["title", "name", "headline"]) ?? "Untitled"
        let summary = firstString(value, keys: ["summary", "description", "excerpt"])
        let publishedAt = firstString(value, keys: ["publishedAt", "createdAt", "datePublished"]) ?? DateFormatters.string()
        return EntryListItem(
            entryId: record.uri,
            title: title,
            summary: summary,
            publishedAt: publishedAt,
            thumbnailUrl: thumbnail(from: value),
            thumbnailFallbackUrl: nil
        )
    }

    static func parseDetail(record: GenericRepoRecord) -> EntryDetail {
        let value = record.value.object ?? [:]
        let list = parseListItem(record: record)
        let content = firstString(value, keys: ["contentHtml", "html", "content", "body", "text"]) ?? list.summary ?? ""
        let original = firstString(value, keys: ["url", "uri", "originalUrl", "canonicalUrl"])
        let site = firstString(value, keys: ["site", "origin"])
        let path = firstString(value, keys: ["path"])
        let embed = original ?? embedURL(site: site, path: path)
        let strongRef = strongRef(from: value["bskyPostRef"])
        return EntryDetail(
            entryId: record.uri,
            title: list.title,
            publishedAt: list.publishedAt,
            contentHtml: content,
            originalUrl: original,
            embedUrl: embed,
            bskyPostUri: strongRef?.uri,
            bskyPostCid: strongRef?.cid
        )
    }

    static func recordBelongsToPublication(_ value: JSONValue, publicationAtUri: String) -> Bool {
        guard let object = value.object else { return false }
        return firstString(object, keys: ["publication", "publicationUri", "publicationId"]) == publicationAtUri
    }

    private static func firstString(_ object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func thumbnail(from object: [String: JSONValue]) -> String? {
        if let direct = firstString(object, keys: ["thumbnail", "thumbnailUrl", "image", "coverImage"]) {
            return direct
        }
        if let imageObject = object["image"]?.object {
            return firstString(imageObject, keys: ["url", "ref"])
        }
        return nil
    }

    private static func embedURL(site: String?, path: String?) -> String? {
        guard let site else { return nil }
        if let path, let url = URL(string: path, relativeTo: URL(string: site)) {
            return url.absoluteString
        }
        return site
    }

    private static func strongRef(from value: JSONValue?) -> StrongRef? {
        guard let object = value?.object,
              let uri = object["uri"]?.string,
              let cid = object["cid"]?.string
        else { return nil }
        return StrongRef(uri: uri, cid: cid)
    }
}
