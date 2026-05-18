import Foundation

struct GatewayHTTPResult: Sendable {
    let statusCode: Int
    let etagHeader: String?
    let body: Data
}

/// JSON bundle returned by **`GET /v1/sync/preferences`** (`PreferenceSyncService.finalizePreferences`).
struct SyncPreferencesEnvelope: Codable, Sendable {
    let etag: String?
    let revision: String?
    let cid: String?
    let cachedAt: String?
    let record: PreferencesRecord?
}

/// Authenticated calls to **`SocialWireAPIEnvironment.baseURL`** (DPoP + access JWT), mirroring PDS **`XRPCClient`** semantics.
@MainActor
final class SocialWireGatewayClient {
    private let auth: ATProtoOAuthService
    private let baseURL: URL
    private let urlSession: URLSession

    init(
        auth: ATProtoOAuthService,
        baseURL: URL = SocialWireAPIEnvironment.baseURL,
        urlSession: URLSession = .shared
    ) {
        self.auth = auth
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func fetchSyncPreferences(ifNoneMatch: String?) async throws -> GatewayHTTPResult {
        try await authorizedGET(path: "/v1/sync/preferences", query: [:], ifNoneMatch: ifNoneMatch)
    }

    func fetchCachedPdsRecord(collection: String, rkey: String, ifNoneMatch: String?) async throws -> GatewayHTTPResult {
        try await authorizedGET(
            path: "/v1/pds/cache/record",
            query: ["collection": collection, "rkey": rkey],
            ifNoneMatch: ifNoneMatch
        )
    }

    // MARK: - Private

    private func authorizedGET(
        path: String,
        query: [String: String],
        ifNoneMatch: String?
    ) async throws -> GatewayHTTPResult {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw SocialWireError.invalidURL
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            throw SocialWireError.invalidURL
        }

        let session = try await auth.validSession()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        try await authorize(&request, session: session)

        let trimmedNM = trimmedEntityTag(ifNoneMatch)
        if let trimmedNM, !trimmedNM.isEmpty {
            request.setValue(trimmedNM, forHTTPHeaderField: "If-None-Match")
        }

        let (firstData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing gateway response.")
        }

        await auth.dpop.updateNonce(from: http)

        let initial = GatewayHTTPResult(
            statusCode: http.statusCode,
            etagHeader: http.value(forHTTPHeaderField: "ETag"),
            body: firstData
        )

        if [401, 400].contains(http.statusCode), http.value(forHTTPHeaderField: "DPoP-Nonce") != nil {
            var retry = URLRequest(url: url)
            retry.httpMethod = "GET"
            retry.setValue("application/json", forHTTPHeaderField: "Accept")
            try await authorize(&retry, session: session)
            if let trimmedNM, !trimmedNM.isEmpty {
                retry.setValue(trimmedNM, forHTTPHeaderField: "If-None-Match")
            }

            let (retryData, retryResponse) = try await urlSession.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing gateway response.")
            }
            await auth.dpop.updateNonce(from: retryHttp)
            return GatewayHTTPResult(
                statusCode: retryHttp.statusCode,
                etagHeader: retryHttp.value(forHTTPHeaderField: "ETag"),
                body: retryData
            )
        }

        return initial
    }

    private func authorize(_ request: inout URLRequest, session: AuthSession) async throws {
        guard let url = request.url else { throw SocialWireError.invalidURL }
        let method = request.httpMethod ?? "GET"

        request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            try await auth.dpop.proof(method: method, url: url, accessToken: session.accessToken),
            forHTTPHeaderField: "DPoP"
        )
    }

    private func trimmedEntityTag(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.first == "\"" {
            let drop = trimmed.dropFirst().dropLast(trimmed.hasSuffix("\"") ? 1 : 0)
            return drop.isEmpty ? nil : String(drop)
        }
        return trimmed
    }
}
