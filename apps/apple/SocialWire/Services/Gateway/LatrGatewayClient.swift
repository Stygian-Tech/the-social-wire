import Foundation

/// Authenticated L@tr Link gateway mutations (`/v1/latr/saves*`) with upstream PDS DPoP.
@MainActor
final class LatrGatewayClient {
    private static let upstreamDPoPHeader = "X-ATProto-Upstream-DPoP"

    private let auth: ATProtoOAuthService
    private let baseURL: URL
    private let urlSession: URLSession

    init(
        auth: ATProtoOAuthService,
        baseURL: URL = LatrGatewayEnvironment.baseURL,
        urlSession: URLSession = .shared
    ) {
        self.auth = auth
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func saveURL(_ url: URL, title: String?, excerpt: String?) async throws {
        var body: [String: String] = [
            "kind": "url",
            "url": url.absoluteString,
        ]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["title"] = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let excerpt, !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["excerpt"] = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await authorizedRequest(
            method: "POST",
            path: "/v1/latr/saves",
            body: try JSONEncoder().encode(body)
        )
    }

    func saveNativeSubject(subjectURI: String, linkedWebURL: String?) async throws {
        var body: [String: String] = [
            "kind": "subject",
            "subjectUri": subjectURI,
        ]
        if let linkedWebURL, !linkedWebURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["linkedWebUrl"] = linkedWebURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await authorizedRequest(
            method: "POST",
            path: "/v1/latr/saves",
            body: try JSONEncoder().encode(body)
        )
    }

    func deleteSave(itemRkey: String) async throws {
        try await authorizedRequest(
            method: "DELETE",
            path: "/v1/latr/saves/\(itemRkey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemRkey)",
            body: nil
        )
    }

    func archiveSave(itemRkey: String) async throws {
        try await patchSaveState(itemRkey: itemRkey, state: "archived")
    }

    func unarchiveSave(itemRkey: String) async throws {
        try await patchSaveState(itemRkey: itemRkey, state: "unread")
    }

    func listSavedItems() async throws -> [RepoRecord<LatrSavedItemRecord>] {
        let data = try await authorizedRequestData(
            method: "GET",
            path: "/v1/latr/saves",
            body: nil
        )
        let decoded = try JSONDecoder().decode(LatrGatewaySavedItemsResponse.self, from: data)
        return decoded.records
    }

    private func patchSaveState(itemRkey: String, state: String) async throws {
        let encodedRkey = itemRkey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemRkey
        try await authorizedRequest(
            method: "PATCH",
            path: "/v1/latr/saves/\(encodedRkey)/state",
            body: try JSONEncoder().encode(["state": state])
        )
    }

    private func authorizedRequest(method: String, path: String, body: Data?) async throws {
        _ = try await authorizedRequestData(method: method, path: path, body: body)
    }

    private func authorizedRequestData(method: String, path: String, body: Data?) async throws -> Data {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw SocialWireError.invalidURL
        }
        guard let url = comps.url else {
            throw SocialWireError.invalidURL
        }

        let session = try await auth.validSession()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        try await authorize(
            &request,
            session: session,
            gatewayPath: path,
            gatewayMethod: method
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing L@tr gateway response.")
        }
        await auth.dpop.updateNonce(from: http)

        if [401, 400].contains(http.statusCode), http.value(forHTTPHeaderField: "DPoP-Nonce") != nil {
            var retry = URLRequest(url: url)
            retry.httpMethod = method
            retry.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                retry.httpBody = body
                retry.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            try await authorize(
                &retry,
                session: session,
                gatewayPath: path,
                gatewayMethod: method
            )
            let (retryData, retryResponse) = try await urlSession.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing L@tr gateway response.")
            }
            await auth.dpop.updateNonce(from: retryHttp)
            try validateResponse(retryHttp, data: retryData)
            return retryData
        }

        try validateResponse(http, data: data)
        return data
    }

    private func validateResponse(_ http: HTTPURLResponse, data: Data) throws {
        guard (200 ..< 300).contains(http.statusCode) else {
            if let message = try? JSONDecoder().decode(LatrGatewayErrorBody.self, from: data).resolvedMessage {
                throw SocialWireError.badResponse(message)
            }
            throw SocialWireError.badResponse("L@tr gateway request failed (\(http.statusCode)).")
        }
    }

    private func authorize(
        _ request: inout URLRequest,
        session: AuthSession,
        gatewayPath: String,
        gatewayMethod: String
    ) async throws {
        guard let url = request.url else { throw SocialWireError.invalidURL }
        let method = request.httpMethod ?? gatewayMethod

        request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            try await auth.dpop.proof(method: method, url: url, accessToken: session.accessToken),
            forHTTPHeaderField: "DPoP"
        )

        if let clientId = LatrGatewayEnvironment.developerClientId,
           let apiKey = LatrGatewayEnvironment.developerApiKey {
            request.setValue(clientId, forHTTPHeaderField: LatrGatewayEnvironment.clientIdHeaderName)
            request.setValue(apiKey, forHTTPHeaderField: LatrGatewayEnvironment.apiKeyHeaderName)
        } else if let credential = LatrGatewayEnvironment.officialClientCredential {
            request.setValue(credential, forHTTPHeaderField: LatrGatewayEnvironment.officialClientHeaderName)
        }

        if let xrpcMethod = Self.pdsXrpcMethod(gatewayMethod: gatewayMethod, path: gatewayPath) {
            let pdsXrpcURL = session.pdsURL
                .appending(path: "xrpc")
                .appending(path: xrpcMethod)
            let upstreamHTTPMethod = Self.pdsXrpcHTTPMethod(
                gatewayMethod: gatewayMethod,
                path: gatewayPath
            )
            let upstreamProof = try await auth.dpop.proof(
                method: upstreamHTTPMethod,
                url: pdsXrpcURL,
                accessToken: session.accessToken
            )
            request.setValue(upstreamProof, forHTTPHeaderField: Self.upstreamDPoPHeader)
        }
    }

    private static func pdsXrpcHTTPMethod(gatewayMethod: String, path: String) -> String {
        let method = gatewayMethod.uppercased()
        if method == "GET", path == "/v1/latr/saves" {
            return "GET"
        }
        return "POST"
    }

    private static func pdsXrpcMethod(gatewayMethod: String, path: String) -> String? {
        let method = gatewayMethod.uppercased()
        if method == "GET", path == "/v1/latr/saves" {
            return "com.atproto.repo.listRecords"
        }
        if method == "POST" && path == "/v1/latr/saves" {
            return "com.atproto.repo.createRecord"
        }
        if method == "PATCH", path.contains("/v1/latr/saves/"), path.hasSuffix("/state") {
            return "com.atproto.repo.putRecord"
        }
        if method == "DELETE", path.hasPrefix("/v1/latr/saves/") {
            return "com.atproto.repo.deleteRecord"
        }
        return nil
    }
}

private struct LatrGatewayErrorBody: Decodable {
    var message: String?
    var error: String?

    var resolvedMessage: String? {
        message ?? error
    }
}

private struct LatrGatewaySavedItemsResponse: Decodable {
    let records: [RepoRecord<LatrSavedItemRecord>]
}
