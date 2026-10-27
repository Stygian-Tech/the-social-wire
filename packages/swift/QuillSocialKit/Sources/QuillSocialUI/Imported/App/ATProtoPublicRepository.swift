#if os(iOS)
import Foundation

enum ATProtoPublicRepository {
    static func resolveDID(for actor: String) async throws -> String {
        if actor.hasPrefix("did:") { return actor }
        var components = URLComponents(
            string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle"
        )!
        components.queryItems = [URLQueryItem(name: "handle", value: actor)]
        guard let url = components.url else { throw URLError(.badURL) }
        let data = try await jsonData(from: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let did = object["did"] as? String else { throw URLError(.cannotParseResponse) }
        return did
    }

    static func record(uri: String) async throws -> Data {
        let parts = uri.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "at:",
              let collection = parts.dropFirst(2).first else { throw URLError(.badURL) }
        let repo = String(parts[1])
        let pds = try await resolvePDS(for: repo)
        var components = URLComponents(
            url: pds.appending(path: "xrpc/com.atproto.repo.getRecord"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "repo", value: repo),
            URLQueryItem(name: "collection", value: String(collection)),
            URLQueryItem(name: "rkey", value: String(parts[3])),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        return try await jsonData(from: url)
    }

    static func blobURL(did: String, cid: String) async throws -> URL {
        let pds = try await resolvePDS(for: did)
        var components = URLComponents(
            url: pds.appending(path: "xrpc/com.atproto.sync.getBlob"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "did", value: did),
            URLQueryItem(name: "cid", value: cid),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    static func listRecords(parameters: [String: String]) async throws -> Data {
        guard let did = parameters["repo"] else {
            throw URLError(.badURL)
        }

        let pds = try await resolvePDS(for: did)
        var components = URLComponents(
            url: pds.appending(path: "xrpc/com.atproto.repo.listRecords"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }

        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return try await jsonData(from: url)
    }

    private static func resolvePDS(for did: String) async throws -> URL {
        let documentURL: URL

        if did.wholeMatch(of: /did:plc:[a-z2-7]{24}/) != nil {
            documentURL = URL(string: "https://plc.directory/\(did)")!
        } else if did.hasPrefix("did:web:") {
            let host = String(did.dropFirst("did:web:".count))
            guard
                !host.isEmpty,
                !host.contains(":"),
                !host.contains("%"),
                !host.contains("/")
            else {
                throw URLError(.badURL)
            }
            documentURL = URL(string: "https://\(host)/.well-known/did.json")!
        } else {
            throw URLError(.badURL)
        }

        let data = try await jsonData(from: documentURL)
        guard
            let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            document["id"] as? String == did,
            let services = document["service"] as? [[String: Any]],
            let service = services.first(where: {
                let identifier = $0["id"] as? String
                return (identifier == "#atproto_pds" || identifier == "\(did)#atproto_pds")
                    && $0["type"] as? String == "AtprotoPersonalDataServer"
            }),
            let endpoint = service["serviceEndpoint"] as? String,
            let pds = secureOrigin(endpoint)
        else {
            throw URLError(.cannotParseResponse)
        }

        return pds
    }

    private static func secureOrigin(_ value: String) -> URL? {
        guard
            let url = URL(string: value),
            url.scheme == "https",
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil,
            url.path.isEmpty || url.path == "/",
            let host = url.host,
            host.contains("."),
            host != "localhost",
            !host.hasSuffix(".localhost"),
            !host.hasSuffix(".local"),
            !host.contains(":"),
            host.range(
                of: #"^\d+\.\d+\.\d+\.\d+$"#,
                options: .regularExpression
            ) == nil
        else {
            return nil
        }

        return url
    }

    private static func jsonData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            200..<300 ~= httpResponse.statusCode,
            httpResponse.mimeType == "application/json"
                || httpResponse.mimeType == "application/did+ld+json"
                || httpResponse.mimeType == "application/did+json"
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

#endif
