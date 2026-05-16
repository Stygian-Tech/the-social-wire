import Foundation

actor ATProtoResolver {
    private let publicAppView = URL(string: "https://public.api.bsky.app")!
    private let plcDirectory = URL(string: "https://plc.directory")!
    private var pdsCache: [String: URL] = [:]
    private var handleCache: [String: String] = [:]

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
        let url = plcDirectory.appending(path: did)
        let doc: DIDDocument = try await fetchJSON(url)
        guard let endpoint = doc.service?.first(where: {
            $0.id == "#atproto_pds" || $0.id.hasSuffix("#atproto_pds") || $0.type == "AtprotoPersonalDataServer"
        })?.serviceEndpoint,
              let pdsURL = URL(string: PublicURLNormalizer.normalizeHttpURLToHTTPS(endpoint))
        else { throw SocialWireError.badResponse("Could not resolve PDS for \(did).") }
        pdsCache[did] = pdsURL
        return pdsURL
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SocialWireError.badResponse("Request failed for \(url.host ?? url.absoluteString).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
