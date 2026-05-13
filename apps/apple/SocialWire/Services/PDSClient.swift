import Foundation

/// XRPC helper for reading and writing The Social Wire's ATProto records
/// directly on the user's PDS.
///
/// - `com.thesocialwire.folder`           — user folders
/// - `com.thesocialwire.publicationPrefs` — folder assignment + hidden flag
actor PDSClient {
    private let session: AuthSession

    /// Cache repo DID → PDS XRPC origin for anonymous `com.atproto.repo.*` reads (PLC-resolved).
    private var pdsOriginByRepoDid: [String: String] = [:]

    init(session: AuthSession) {
        self.session = session
    }

    // ── Lexicon constants ─────────────────────────────────────────────────────

    static let collectionFolder = "com.thesocialwire.folder"
    static let collectionPubPrefs = "com.thesocialwire.publicationPrefs"
    static let collectionEntry = "site.standard.entry"

    private static let publicAppView = URL(string: "https://public.api.bsky.app")!
    private static let plcDirectoryRoot = URL(
        string: ProcessInfo.processInfo.environment["ATPROTO_PLC_URL"] ?? "https://plc.directory"
    )!

    private static let maxFollows = 500
    private static let followPageLimit = 100
    private static let discoveryBatchSize = 25

    // ── Folders ───────────────────────────────────────────────────────────────

    func listFolders() async throws -> [FolderModel] {
        let records: ListRecordsResponse<FolderRecord> = try await listRecords(
            collection: Self.collectionFolder
        )
        return records.records.map {
            FolderModel(
                id: rkeyFromURI($0.uri),
                name: $0.value.name,
                icon: $0.value.icon,
                iconImageURL: $0.value.iconImage.flatMap(URL.init(string:)),
                sortOrder: $0.value.sortOrder ?? 0
            )
        }
        .sorted { $0.sortOrder < $1.sortOrder }
    }

    func createFolder(name: String, icon: String? = nil) async throws {
        let record = FolderRecord(
            type: Self.collectionFolder,
            name: name,
            sortOrder: 0,
            icon: icon,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        try await createRecord(collection: Self.collectionFolder, record: record)
    }

    func deleteFolder(rkey: String) async throws {
        try await deleteRecord(collection: Self.collectionFolder, rkey: rkey)
    }

    // ── Publication prefs ─────────────────────────────────────────────────────

    func listPublicationPrefs() async throws -> [PublicationPrefsRecord] {
        let records: ListRecordsResponse<PublicationPrefsRecord> = try await listRecords(
            collection: Self.collectionPubPrefs
        )
        return records.records.map(\.value)
    }

    func setPublicationFolder(
        publicationId: String,
        folderId: String?,
        existingRkey: String? = nil
    ) async throws {
        let rkey = existingRkey ?? generateTID()
        let record = PublicationPrefsRecord(
            type: Self.collectionPubPrefs,
            publicationId: publicationId,
            folderId: folderId,
            sortOrder: 0,
            hidden: false,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        try await putRecord(collection: Self.collectionPubPrefs, rkey: rkey, record: record)
    }

    // ── Discovery ─────────────────────────────────────────────────────────────

    func discoveredPublications(for did: String) async throws -> [PublicationModel] {
        var follows: [FollowProfile] = []
        var cursor: String?

        repeat {
            let page = try await getFollows(actor: did, cursor: cursor)
            follows.append(contentsOf: page.follows)
            cursor = page.cursor
        } while cursor != nil && follows.count < Self.maxFollows

        let discoveredFollows = Array(follows.prefix(Self.maxFollows))
        var publications: [PublicationModel] = []

        for batchStart in stride(from: 0, to: discoveredFollows.count, by: Self.discoveryBatchSize) {
            let batchEnd = min(batchStart + Self.discoveryBatchSize, discoveredFollows.count)
            let batch = Array(discoveredFollows[batchStart..<batchEnd])

            let batchResults = await withTaskGroup(of: PublicationModel?.self) { group in
                for follow in batch {
                    group.addTask {
                        do {
                            let records: ListRecordsResponse<EntryRecordValue> = try await self.listPublicRecords(
                                repo: follow.did,
                                collection: Self.collectionEntry,
                                limit: 1,
                                reverse: false
                            )
                            guard !records.records.isEmpty else { return nil }
                            return PublicationModel(
                                publicationId: follow.did,
                                authorDID: follow.did,
                                title: follow.displayName ?? follow.handle,
                                avatarURL: follow.avatar.flatMap(URL.init(string:))
                            )
                        } catch {
                            return nil
                        }
                    }
                }

                var results: [PublicationModel] = []
                for await publication in group {
                    if let publication {
                        results.append(publication)
                    }
                }
                return results
            }

            publications.append(contentsOf: batchResults)
        }

        return publications
    }

    // ── Content ───────────────────────────────────────────────────────────────

    func entries(for pubId: String) async throws -> [EntryModel] {
        let records: ListRecordsResponse<EntryRecordValue> = try await listPublicRecords(
            repo: pubId,
            collection: Self.collectionEntry,
            limit: 50,
            reverse: true
        )
        let iso = ISO8601DateFormatter()

        return records.records.map { record in
            let fields = parseEntryValue(record.value)
            return EntryModel(
                entryId: record.uri,
                title: fields.title,
                summary: fields.summary,
                publishedAt: iso.date(from: fields.publishedAt) ?? Date()
            )
        }
    }

    func entryDetail(id: String) async throws -> EntryDetailModel {
        guard let parsed = parseATURI(id) else {
            throw PDSError.invalidATURI
        }

        let record: GetRecordResponse<EntryRecordValue> = try await getPublicRecord(
            repo: parsed.did,
            collection: parsed.collection,
            rkey: parsed.rkey
        )
        let fields = parseEntryValue(record.value)
        let iso = ISO8601DateFormatter()

        return EntryDetailModel(
            entryId: id,
            title: fields.title,
            publishedAt: iso.date(from: fields.publishedAt) ?? Date(),
            contentHTML: fields.contentHTML,
            originalURL: fields.originalURL.flatMap(URL.init(string:))
        )
    }

    // ── XRPC helpers ──────────────────────────────────────────────────────────

    private func listRecords<T: Decodable & Sendable>(collection: String) async throws -> ListRecordsResponse<T> {
        let url = session.pdsURL
            .appendingPathComponent("/xrpc/com.atproto.repo.listRecords")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "repo", value: session.did),
            URLQueryItem(name: "collection", value: collection),
            URLQueryItem(name: "limit", value: "100"),
        ]
        let request = authenticatedRequest(url: components.url!)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ListRecordsResponse<T>.self, from: data)
    }

    private func getFollows(actor: String, cursor: String?) async throws -> FollowsResponse {
        let url = Self.publicAppView
            .appendingPathComponent("/xrpc/app.bsky.graph.getFollows")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "actor", value: actor),
            URLQueryItem(name: "limit", value: String(Self.followPageLimit)),
        ]
        if let cursor {
            components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await getPublicJSON(url: components.url!)
    }

    /// Bridgy Fed relay rejects `reverse=true` on `listRecords` (matches web `relayHostOmitsListRecordsReverse`).
    private static func relayHostOmitsListRecordsReverse(pdsOrigin: String) -> Bool {
        guard let host = URL(string: pdsOrigin)?.host?.lowercased() else { return false }
        return host == "atproto.brid.gy" || host.hasSuffix(".brid.gy")
    }

    private func normalizePdsOrigin(_ serviceEndpoint: String) -> String? {
        var s = serviceEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// `com.atproto.repo.*` against a third-party repo requires a repo DID; resolve handles via public App View (no OAuth).
    private func resolveRepoDidForPublicRead(_ handleOrDid: String) async throws -> String {
        var t = handleOrDid.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("@") { t.removeFirst() }
        if t.hasPrefix("did:") { return t }

        var c = URLComponents()
        c.scheme = Self.publicAppView.scheme
        c.host = Self.publicAppView.host
        c.path = "/xrpc/com.atproto.identity.resolveHandle"
        c.queryItems = [URLQueryItem(name: "handle", value: t)]
        guard let url = c.url else { throw PDSError.requestFailed }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PDSError.requestFailed
        }
        struct ResolveBody: Decodable { let did: String? }
        let body = try JSONDecoder().decode(ResolveBody.self, from: data)
        guard let did = body.did else { throw PDSError.requestFailed }
        return did
    }

    private func plcDocumentURL(forDid did: String) -> URL? {
        let enc = did.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? did
        var root = Self.plcDirectoryRoot.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: "\(root)/\(enc)")
    }

    private func pdsOrigin(forRepoDid did: String) async throws -> String {
        if let cached = pdsOriginByRepoDid[did] { return cached }
        guard let plcURL = plcDocumentURL(forDid: did) else { throw PDSError.requestFailed }

        let (data, response) = try await URLSession.shared.data(from: plcURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PDSError.requestFailed
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let services = obj["service"] as? [[String: Any]]
        else { throw PDSError.requestFailed }

        var endpoint: String?
        for s in services {
            let sid = s["id"] as? String
            let stype = s["type"] as? String
            guard let ep = s["serviceEndpoint"] as? String else { continue }
            if sid == "#atproto_pds" || stype == "AtprotoPersonalDataServer" {
                endpoint = ep
                break
            }
        }
        guard let raw = endpoint, let origin = normalizePdsOrigin(raw) else { throw PDSError.requestFailed }
        pdsOriginByRepoDid[did] = origin
        return origin
    }

    private func sortPublicEntryRecordsNewestFirst(
        _ records: [ListRecordsResponse<EntryRecordValue>.Record<EntryRecordValue>]
    ) -> [ListRecordsResponse<EntryRecordValue>.Record<EntryRecordValue>] {
        records.sorted {
            let ka = $0.value.publishedAt ?? $0.value.createdAt ?? ""
            let kb = $1.value.publishedAt ?? $1.value.createdAt ?? ""
            if ka != kb { return ka > kb }
            return $0.uri < $1.uri
        }
    }

    /// Anonymous repo reads against the author's PDS (PLC); never the App View host.
    private func listPublicRecords(
        repo: String,
        collection: String,
        limit: Int,
        cursor: String? = nil,
        reverse: Bool = false
    ) async throws -> ListRecordsResponse<EntryRecordValue> {
        let repoDid = try await resolveRepoDidForPublicRead(repo)
        let pds = try await pdsOrigin(forRepoDid: repoDid)

        let wantReverse = reverse
        let serverReverse = wantReverse && !Self.relayHostOmitsListRecordsReverse(pdsOrigin: pds)
        let sortPageNewestFirst = wantReverse && serverReverse != wantReverse

        var c = URLComponents(string: "\(pds)/xrpc/com.atproto.repo.listRecords")!
        c.queryItems = [
            URLQueryItem(name: "repo", value: repoDid),
            URLQueryItem(name: "collection", value: collection),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "reverse", value: serverReverse ? "true" : "false"),
        ]
        if let cursor {
            c.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        guard let url = c.url else { throw PDSError.requestFailed }

        var decoded: ListRecordsResponse<EntryRecordValue> = try await getPublicJSON(url: url)
        if sortPageNewestFirst {
            decoded = ListRecordsResponse(records: sortPublicEntryRecordsNewestFirst(decoded.records))
        }
        return decoded
    }

    private func getPublicRecord(
        repo: String,
        collection: String,
        rkey: String
    ) async throws -> GetRecordResponse<EntryRecordValue> {
        let repoDid = try await resolveRepoDidForPublicRead(repo)
        let pds = try await pdsOrigin(forRepoDid: repoDid)

        var c = URLComponents(string: "\(pds)/xrpc/com.atproto.repo.getRecord")!
        c.queryItems = [
            URLQueryItem(name: "repo", value: repoDid),
            URLQueryItem(name: "collection", value: collection),
            URLQueryItem(name: "rkey", value: rkey),
        ]
        guard let url = c.url else { throw PDSError.requestFailed }
        return try await getPublicJSON(url: url)
    }

    private func getPublicJSON<T: Decodable & Sendable>(url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PDSError.requestFailed
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func createRecord<T: Encodable>(collection: String, record: T) async throws {
        let url = session.pdsURL.appendingPathComponent("/xrpc/com.atproto.repo.createRecord")
        var request = authenticatedRequest(url: url, method: "POST")
        let body = CreateRecordRequest(repo: session.did, collection: collection, record: record)
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PDSError.requestFailed
        }
    }

    private func putRecord<T: Encodable>(collection: String, rkey: String, record: T) async throws {
        let url = session.pdsURL.appendingPathComponent("/xrpc/com.atproto.repo.putRecord")
        var request = authenticatedRequest(url: url, method: "POST")
        let body = PutRecordRequest(repo: session.did, collection: collection, rkey: rkey, record: record)
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PDSError.requestFailed
        }
    }

    private func deleteRecord(collection: String, rkey: String) async throws {
        let url = session.pdsURL.appendingPathComponent("/xrpc/com.atproto.repo.deleteRecord")
        var request = authenticatedRequest(url: url, method: "POST")
        let body = DeleteRecordRequest(repo: session.did, collection: collection, rkey: rkey)
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PDSError.requestFailed
        }
    }

    private func authenticatedRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func rkeyFromURI(_ uri: String) -> String {
        uri.split(separator: "/").last.map(String.init) ?? uri
    }

    private func parseATURI(_ uri: String) -> (did: String, collection: String, rkey: String)? {
        guard uri.hasPrefix("at://") else { return nil }
        let path = uri.dropFirst("at://".count)
        let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return (did: parts[0], collection: parts[1], rkey: parts[2])
    }

    private func parseEntryValue(_ value: EntryRecordValue) -> (
        title: String,
        publishedAt: String,
        contentHTML: String,
        originalURL: String?,
        summary: String?
    ) {
        (
            title: value.title ?? value.name ?? "Untitled",
            publishedAt: value.publishedAt ?? value.createdAt ?? ISO8601DateFormatter().string(from: Date()),
            contentHTML: value.content ?? value.contentHTML ?? value.text ?? value.body ?? "",
            originalURL: value.url ?? value.externalURL,
            summary: value.summary ?? value.description
        )
    }

    private func generateTID() -> String {
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let chars = Array("234567abcdefghijklmnopqrstuvwxyz")
        var n = ts
        var result = ""
        for _ in 0..<13 {
            result = String(chars[Int(n & 31)]) + result
            n >>= 5
        }
        return result
    }
}

// ── Data models ───────────────────────────────────────────────────────────────

struct FolderModel: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String?
    let iconImageURL: URL?
    let sortOrder: Int
}

struct PublicationModel: Identifiable, Sendable {
    let publicationId: String
    let authorDID: String
    let title: String
    let avatarURL: URL?
    var folderId: String?

    var id: String { publicationId }
}

struct EntryModel: Identifiable, Sendable {
    let entryId: String
    let title: String
    let summary: String?
    let publishedAt: Date

    var id: String { entryId }
}

struct EntryDetailModel: Sendable {
    let entryId: String
    let title: String
    let publishedAt: Date
    let contentHTML: String
    let originalURL: URL?
}

// ── XRPC codable types ────────────────────────────────────────────────────────

private struct ListRecordsResponse<T: Decodable & Sendable>: Decodable, Sendable {
    struct Record<V: Decodable & Sendable>: Decodable, Sendable {
        let uri: String
        let cid: String
        let value: V
    }
    let records: [Record<T>]

    init(records: [Record<T>]) {
        self.records = records
    }
}

private struct GetRecordResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let uri: String
    let cid: String
    let value: T
}

private struct FollowsResponse: Decodable, Sendable {
    let follows: [FollowProfile]
    let cursor: String?
}

private struct FollowProfile: Decodable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
}

private struct EntryRecordValue: Decodable, Sendable {
    let title: String?
    let name: String?
    let publishedAt: String?
    let createdAt: String?
    let content: String?
    let contentHTML: String?
    let text: String?
    let body: String?
    let url: String?
    let externalURL: String?
    let summary: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case title, name, publishedAt, createdAt, content, text, body, url, summary, description
        case contentHTML = "contentHtml"
        case externalURL = "externalUrl"
    }
}

private struct FolderRecord: Codable, Sendable {
    let type: String
    let name: String
    let sortOrder: Int?
    let icon: String?
    let iconImage: String?
    let createdAt: String

    init(type: String, name: String, sortOrder: Int?, icon: String?, createdAt: String) {
        self.type = type; self.name = name; self.sortOrder = sortOrder
        self.icon = icon; self.iconImage = nil; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case type = "$type", name, sortOrder, icon, iconImage, createdAt
    }
}

struct PublicationPrefsRecord: Codable, Sendable {
    let type: String
    let publicationId: String
    let folderId: String?
    let sortOrder: Int?
    let hidden: Bool?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type", publicationId, folderId, sortOrder, hidden, createdAt
    }
}

private struct CreateRecordRequest<T: Encodable>: Encodable {
    let repo: String
    let collection: String
    let record: T
}

private struct PutRecordRequest<T: Encodable>: Encodable {
    let repo: String
    let collection: String
    let rkey: String
    let record: T
}

private struct DeleteRecordRequest: Encodable {
    let repo: String
    let collection: String
    let rkey: String
}

enum PDSError: Error {
    case requestFailed
    case invalidATURI
}
