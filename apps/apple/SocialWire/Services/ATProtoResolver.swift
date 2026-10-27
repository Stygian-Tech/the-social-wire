import Foundation

actor ATProtoResolver {
    private let publicAppView = URL(string: "https://public.api.bsky.app")!
    private let typeaheadService = URL(string: "https://typeahead.waow.tech")!
    private var pdsCache: [String: URL] = [:]
    private var handleCache: [String: String] = [:]
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }) {
        self.transport = transport
    }

    func resolveDID(handleOrDID: String) async throws -> String {
        let normalized = handleOrDID.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("@")
        if normalized.hasPrefix("did:") { return normalized }
        if let cached = handleCache[normalized] { return cached }

        var components = URLComponents(url: publicAppView.appending(path: "xrpc/com.atproto.identity.resolveHandle"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "handle", value: normalized)]
        guard let url = components?.url else { throw SocialWireError.invalidURL }

        let response: ResolveHandleResponse = try await fetchJSON(url)
        handleCache[normalized] = response.did
        return response.did
    }

    func resolvePDSURL(did: String) async throws -> URL {
        if let cached = pdsCache[did] { return cached }
        let url = try Self.didDocumentURL(did: did)
        let doc: DIDDocument = try await fetchJSON(url)
        guard let endpoint = doc.service?.first(where: {
            $0.id == "#atproto_pds" || $0.id.hasSuffix("#atproto_pds") || $0.type == "AtprotoPersonalDataServer"
        })?.serviceEndpoint,
              let pdsURL = URL(string: PublicURLNormalizer.normalizeHttpURLToHTTPS(endpoint))
        else { throw SocialWireError.badResponse("Could not resolve PDS for \(did).") }
        pdsCache[did] = pdsURL
        return pdsURL
    }

    /// AT Protocol's did:web identities use a hostname and the well-known DID document.
    /// Do not send these identities to the PLC directory or interpret DID input as a URL.
    nonisolated static func didDocumentURL(did: String) throws -> URL {
        if did.hasPrefix("did:plc:"), !did.dropFirst("did:plc:".count).isEmpty {
            return URL(string: "https://plc.directory")!.appending(path: did)
        }
        guard did.hasPrefix("did:web:") else { throw SocialWireError.invalidURL }
        let host = String(did.dropFirst("did:web:".count))
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !host.contains(where: { ":%/@?#\\".contains($0) }) else { throw SocialWireError.invalidURL }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/.well-known/did.json"
        guard let url = components.url, url.host == host else { throw SocialWireError.invalidURL }
        return url
    }

    func searchLoginActors(_ value: String, limit: Int = 6) async throws -> [LoginActorSuggestion] {
        guard let query = Self.loginHandleSearchQuery(value) else { return [] }
        var components = URLComponents(
            url: typeaheadService.appending(path: "xrpc/app.bsky.actor.searchActorsTypeahead"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { throw SocialWireError.invalidURL }
        let response: LoginActorSearchResponse = try await fetchJSON(url)
        return response.actors
    }

    static func loginHandleSearchQuery(_ value: String) -> String? {
        var query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.hasPrefix("@") { query.removeFirst() }
        guard query.count >= 2,
              !query.contains(":"),
              !query.contains("/"),
              !query.contains(where: { $0.isWhitespace })
        else { return nil }
        return query
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SocialWireError.badResponse("Request failed for \(url.host ?? url.absoluteString).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct LoginActorSearchResponse: Decodable {
    let actors: [LoginActorSuggestion]
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
