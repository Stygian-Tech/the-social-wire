import Foundation

@MainActor
final class XRPCClient {
    private let auth: ATProtoOAuthService
    private let resolver: ATProtoResolver
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(auth: ATProtoOAuthService, resolver: ATProtoResolver) {
        self.auth = auth
        self.resolver = resolver
    }

    func currentDID() async throws -> String {
        try await auth.validSession().did
    }

    func publicGet<T: Decodable>(_ base: URL, method: String, query: [String: String?] = [:]) async throws -> T {
        let url = try xrpcURL(base: base, method: method, query: query)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    func authorizedGet<T: Decodable>(_ base: URL, method: String, query: [String: String?] = [:]) async throws -> T {
        let session = try await auth.validSession()
        let url = try xrpcURL(base: base, method: method, query: query)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await sign(&request, session: session)
        return try await sendWithDPoPRetry(request, session: session)
    }

    func authorizedPost<Body: Encodable, T: Decodable>(_ base: URL, method: String, body: Body) async throws -> T {
        let session = try await auth.validSession()
        let url = try xrpcURL(base: base, method: method)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(body)
        try await sign(&request, session: session)
        return try await sendWithDPoPRetry(request, session: session)
    }

    func listRecords<Value: Codable & Sendable>(
        repo: String,
        collection: String,
        limit: Int = 100,
        cursor: String? = nil,
        reverse: Bool? = nil,
        authorized: Bool
    ) async throws -> ListRecordsResponse<Value> {
        let session = authorized ? try await auth.validSession() : nil
        let effectiveRepo = authorized ? (session?.did ?? repo) : repo
        let base: URL
        if let session {
            base = session.pdsURL
        } else {
            base = try await resolver.resolvePDSURL(did: repo)
        }
        let query: [String: String?] = [
            "repo": effectiveRepo,
            "collection": collection,
            "limit": String(limit),
            "cursor": cursor,
            "reverse": reverse.map { $0 ? "true" : "false" }
        ]
        if authorized {
            return try await authorizedGet(base, method: "com.atproto.repo.listRecords", query: query)
        }
        return try await publicGet(base, method: "com.atproto.repo.listRecords", query: query)
    }

    func listGenericRecords(repo: String, collection: String, limit: Int = 50, cursor: String? = nil, reverse: Bool? = nil) async throws -> GenericListRecordsResponse {
        let base = try await resolver.resolvePDSURL(did: repo)
        return try await publicGet(
            base,
            method: "com.atproto.repo.listRecords",
            query: [
                "repo": repo,
                "collection": collection,
                "limit": String(limit),
                "cursor": cursor,
                "reverse": reverse.map { $0 ? "true" : "false" }
            ]
        )
    }

    func getGenericRecord(repo: String, collection: String, rkey: String) async throws -> GenericRepoRecord {
        let base = try await resolver.resolvePDSURL(did: repo)
        let response: GenericRepoRecord = try await publicGet(
            base,
            method: "com.atproto.repo.getRecord",
            query: ["repo": repo, "collection": collection, "rkey": rkey]
        )
        return response
    }

    func putRecord<Record: Encodable>(collection: String, rkey: String, record: Record) async throws {
        let session = try await auth.validSession()
        let body = PutRecordRequest(repo: session.did, collection: collection, rkey: rkey, record: AnyEncodable(record))
        let _: EmptyResponse = try await authorizedPost(session.pdsURL, method: "com.atproto.repo.putRecord", body: body)
    }

    func createRecord<Record: Encodable>(collection: String, record: Record) async throws {
        let session = try await auth.validSession()
        let body = CreateRecordRequest(repo: session.did, collection: collection, record: AnyEncodable(record))
        let _: EmptyResponse = try await authorizedPost(session.pdsURL, method: "com.atproto.repo.createRecord", body: body)
    }

    func deleteRecord(collection: String, rkey: String) async throws {
        let session = try await auth.validSession()
        let body = DeleteRecordRequest(repo: session.did, collection: collection, rkey: rkey)
        let _: EmptyResponse = try await authorizedPost(session.pdsURL, method: "com.atproto.repo.deleteRecord", body: body)
    }

    private func xrpcURL(base: URL, method: String, query: [String: String?] = [:]) throws -> URL {
        var components = URLComponents(url: base.appending(path: "xrpc/\(method)"), resolvingAgainstBaseURL: false)
        components?.queryItems = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        guard let url = components?.url else { throw SocialWireError.invalidURL }
        return url
    }

    private func sign(_ request: inout URLRequest, session: AuthSession) async throws {
        guard let url = request.url else { throw SocialWireError.invalidURL }
        let method = request.httpMethod ?? "GET"
        request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(try await auth.dpop.proof(method: method, url: url, accessToken: session.accessToken), forHTTPHeaderField: "DPoP")
    }

    private func sendWithDPoPRetry<T: Decodable>(_ request: URLRequest, session: AuthSession) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocialWireError.badResponse("Missing response.") }
        await auth.dpop.updateNonce(from: http)
        if [400, 401].contains(http.statusCode), http.value(forHTTPHeaderField: "DPoP-Nonce") != nil {
            var retry = request
            try await sign(&retry, session: session)
            return try await send(retry)
        }
        return try decode(data: data, response: http)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocialWireError.badResponse("Missing response.") }
        return try decode(data: data, response: http)
    }

    private func decode<T: Decodable>(data: Data, response: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            throw SocialWireError.badResponse("XRPC request failed with HTTP \(response.statusCode).")
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try jsonDecoder.decode(T.self, from: data)
    }
}

private struct PutRecordRequest: Encodable {
    let repo: String
    let collection: String
    let rkey: String
    let record: AnyEncodable
}

private struct CreateRecordRequest: Encodable {
    let repo: String
    let collection: String
    let record: AnyEncodable
}

private struct DeleteRecordRequest: Encodable {
    let repo: String
    let collection: String
    let rkey: String
}

private struct EmptyResponse: Decodable {}

struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
