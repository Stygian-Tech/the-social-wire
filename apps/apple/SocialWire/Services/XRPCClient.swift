import Foundation
import OSLog

@MainActor
final class XRPCClient {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TheSocialWire", category: "XRPC")

    private let auth: ATProtoOAuthService
    private let resolver: ATProtoResolver
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(auth: ATProtoOAuthService, resolver: ATProtoResolver,
         transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         }) {
        self.auth = auth
        self.resolver = resolver
        self.transport = transport
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

    func authorizedServiceProxyGet<T: Decodable>(
        method: String,
        service: String,
        query: [String: String?] = [:]
    ) async throws -> T {
        let session = try await auth.validSession()
        let url = try xrpcURL(base: session.pdsURL, method: method, query: query)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(service, forHTTPHeaderField: "atproto-proxy")
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

    /// Signed `com.atproto.repo.getRecord` for the signed-in user's repo. Returns **`nil`** when the record does not exist (404).
    func authorizedRepoGetRecord<Value: Decodable>(collection: String, rkey: String) async throws -> RepoRecord<Value>? {
        let session = try await auth.validSession()
        let query: [String: String?] = [
            "repo": session.did,
            "collection": collection,
            "rkey": rkey,
        ]
        let url = try xrpcURL(base: session.pdsURL, method: "com.atproto.repo.getRecord", query: query)

        func parseRepoRecordOptional(_ data: Data, _ http: HTTPURLResponse) throws -> RepoRecord<Value>? {
            if http.statusCode == 404 { return nil }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw SocialWireError.badResponse("XRPC request failed with HTTP \(http.statusCode).")
            }
            return try jsonDecoder.decode(RepoRecord<Value>.self, from: data)
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await sign(&request, session: session)

        let (data, response) = try await sendAuthorized(request, session: session)
        return try parseRepoRecordOptional(data, response)
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

    func listAuthorizedGenericRecords(
        collection: String,
        limit: Int = 100,
        cursor: String? = nil
    ) async throws -> GenericListRecordsResponse {
        let session = try await auth.validSession()
        return try await authorizedGet(
            session.pdsURL,
            method: "com.atproto.repo.listRecords",
            query: [
                "repo": session.did,
                "collection": collection,
                "limit": String(limit),
                "cursor": cursor,
            ]
        )
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

    @discardableResult
    func createRecord<Record: Encodable>(collection: String, record: Record) async throws -> String {
        try await createRecordReference(collection: collection, record: record).uri
    }

    func createRecordReference<Record: Encodable>(collection: String, record: Record) async throws -> StrongRef {
        let session = try await auth.validSession()
        let body = CreateRecordRequest(repo: session.did, collection: collection, record: AnyEncodable(record))
        let response: CreateRecordResponse = try await authorizedPost(
            session.pdsURL,
            method: "com.atproto.repo.createRecord",
            body: body
        )
        return StrongRef(uri: response.uri, cid: response.cid)
    }

    func uploadBlob(data: Data, mimeType: String) async throws -> ATProtoBlob {
        let session = try await auth.validSession()
        let url = try xrpcURL(base: session.pdsURL, method: "com.atproto.repo.uploadBlob")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        try await sign(&request, session: session)
        let response: UploadBlobResponse = try await sendWithDPoPRetry(request, session: session)
        return response.blob
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
        let (data, response) = try await sendAuthorized(request, session: session)
        return try decode(data: data, response: response)
    }

    private func sendAuthorized(_ request: URLRequest, session: AuthSession) async throws -> (Data, HTTPURLResponse) {
        var currentSession = session
        // A resource rejection permits one token refresh; each token gets the existing bounded
        // nonce ceremony. Only the viewer's own PDS may trigger credential recovery.
        for recovery in 0 ... 1 {
            var currentRequest = request
            if recovery > 0 { try await sign(&currentRequest, session: currentSession) }
            for attempt in 1 ... 3 {
                let (data, response) = try await transport(currentRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw SocialWireError.badResponse("Missing response.")
                }
                await auth.dpop.updateNonce(from: http)
                let nonceChallenge = [400, 401].contains(http.statusCode)
                    && http.value(forHTTPHeaderField: "DPoP-Nonce") != nil
                if nonceChallenge, attempt < 3 {
                    Self.logger.debug("XRPC DPoP nonce challenge, attempt \(attempt)")
                    currentRequest = request
                    try await sign(&currentRequest, session: currentSession)
                    continue
                }
                let invalidToken = Self.isInvalidTokenResponse(http, data: data)
                if http.statusCode == 401, (!nonceChallenge || invalidToken),
                   Self.hasSameOrigin(request.url, currentSession.pdsURL) {
                    if recovery == 0 {
                        currentSession = try await auth.refreshedSession(rejected: currentSession)
                        break
                    }
                    if invalidToken {
                        auth.invalidateSessionAfterUnauthorizedResponse(rejected: currentSession)
                    }
                }
                return (data, http)
            }
        }
        throw SocialWireError.badResponse("XRPC request exhausted authentication recovery.")
    }

    nonisolated static func isInvalidTokenResponse(_ response: HTTPURLResponse, data: Data) -> Bool {
        guard response.statusCode == 401 else { return false }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let code = (body?["error"] as? String)?.lowercased()
        return ["invalidtoken", "expiredtoken", "invalid_token", "token_expired"].contains(code ?? "")
            || response.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased()
                .contains("error=\"invalid_token\"") == true
    }

    nonisolated private static func hasSameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await transport(request)
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

private struct CreateRecordResponse: Decodable {
    let uri: String
    let cid: String
}

private struct UploadBlobResponse: Decodable {
    let blob: ATProtoBlob
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
