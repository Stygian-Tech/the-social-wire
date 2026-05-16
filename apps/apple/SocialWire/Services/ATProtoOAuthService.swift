import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class ATProtoOAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let scopes = [
        "atproto",
        "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
        "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
        "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
        "repo:com.thesocialwire.entryReadState?action=create&action=update&action=delete",
        "repo:com.latr.saved.external?action=create&action=update&action=delete",
        "repo:com.latr.saved.item?action=create&action=update&action=delete",
        "repo:site.standard.graph.subscription?action=create&action=update&action=delete",
        "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete"
    ].joined(separator: " ")

    @Published private(set) var session: AuthSession?

    let dpop = DPoPService()
    private let keychain = KeychainStore()
    private let resolver = ATProtoResolver()

    private var pkceVerifier: String?
    private var pendingDID: String?
    private var pendingPDSURL: URL?
    private var pendingTokenEndpoint: URL?
    private var pendingAuthorizationIssuer: String?
    private var pendingOAuthState: String?

    func restoreSession() async {
        guard
            let did = keychain.string(for: "oauth.did"),
            let refreshToken = keychain.string(for: "oauth.refreshToken"),
            let pdsString = keychain.string(for: "oauth.pdsURL"),
            let pdsURL = URL(string: pdsString),
            let tokenString = keychain.string(for: "oauth.tokenEndpoint"),
            let tokenEndpoint = URL(string: tokenString)
        else {
            clearSession()
            return
        }

        if let rawKey = keychain.string(for: "oauth.dpopKey") {
            await dpop.replacePrivateKey(base64: rawKey)
        }

        do {
            let tokens = try await refreshTokens(refreshToken: refreshToken, tokenEndpoint: tokenEndpoint)
            persist(did: did, pdsURL: pdsURL, tokenEndpoint: tokenEndpoint, tokens: tokens)
        } catch {
            clearSession()
        }
    }

    func signIn(handle: String) async throws {
        let did = try await resolver.resolveDID(handleOrDID: handle)
        let pdsURL = try await resolver.resolvePDSURL(did: did)
        let asMetadata = try await Self.fetchAuthorizationServerMetadata(pdsURL: pdsURL)

        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(from: verifier)
        let state = UUID().uuidString

        pkceVerifier = verifier
        pendingDID = did
        pendingPDSURL = pdsURL
        pendingTokenEndpoint = asMetadata.tokenEndpoint
        pendingAuthorizationIssuer = asMetadata.issuer
        pendingOAuthState = state

        let requestURI = try await pushedAuthorizationRequest(
            metadata: asMetadata,
            codeChallenge: challenge,
            state: state,
            loginHint: did
        )
        let authURL = try Self.authorizationRedirectURL(
            authorizationEndpoint: asMetadata.authorizationEndpoint,
            requestURI: requestURI
        )

        do {
            let callbackURL: URL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let webSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: ATProtoOAuthConfig.callbackURLScheme) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: SocialWireError.badResponse("OAuth callback did not include a URL."))
                    }
                }
                webSession.presentationContextProvider = self
                webSession.prefersEphemeralWebBrowserSession = false
                webSession.start()
            }
            try await handleCallbackURL(callbackURL)
        } catch {
            resetPendingOAuthState()
            throw error
        }
    }

    func handleCallbackURL(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SocialWireError.badResponse("Invalid OAuth callback URL.")
        }
        let queryItems = components.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        if let oauthError = query["error"], !oauthError.isEmpty {
            let desc = query["error_description"] ?? oauthError
            resetPendingOAuthState()
            throw SocialWireError.badResponse("OAuth error: \(desc)")
        }

        guard let code = query["code"], !code.isEmpty else {
            resetPendingOAuthState()
            throw SocialWireError.badResponse("OAuth callback missing code.")
        }
        guard let state = query["state"], let expectedState = pendingOAuthState, state == expectedState else {
            resetPendingOAuthState()
            throw SocialWireError.badResponse("OAuth state mismatch.")
        }
        if let iss = query["iss"], !iss.isEmpty, let expectedIss = pendingAuthorizationIssuer, iss != expectedIss {
            resetPendingOAuthState()
            throw SocialWireError.badResponse("OAuth issuer mismatch.")
        }
        guard
            let verifier = pkceVerifier,
            let did = pendingDID,
            let pdsURL = pendingPDSURL,
            let tokenEndpoint = pendingTokenEndpoint
        else {
            resetPendingOAuthState()
            throw SocialWireError.badResponse("OAuth session state was lost.")
        }

        let tokens = try await exchangeCode(code: code, verifier: verifier, tokenEndpoint: tokenEndpoint)
        persist(did: did, pdsURL: pdsURL, tokenEndpoint: tokenEndpoint, tokens: tokens)
        resetPendingOAuthState()
    }

    func signOut() {
        clearSession()
    }

    func validSession() async throws -> AuthSession {
        guard let current = session else { throw SocialWireError.notAuthenticated }
        if current.expiresAt.timeIntervalSinceNow > 60 {
            return current
        }
        let tokens = try await refreshTokens(refreshToken: current.refreshToken, tokenEndpoint: current.tokenEndpoint)
        persist(did: current.did, pdsURL: current.pdsURL, tokenEndpoint: current.tokenEndpoint, tokens: tokens)
        return session ?? current
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }

    /// Builds the browser authorization redirect after PAR (`client_id` + `request_uri` only).
    static func authorizationRedirectURL(authorizationEndpoint: URL, requestURI: String) throws -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: ATProtoOAuthConfig.clientID),
            URLQueryItem(name: "request_uri", value: requestURI)
        ]
        guard let url = components?.url else { throw SocialWireError.invalidURL }
        return url
    }

    /// Field map for the pushed-authorization-request body (for tests).
    static func parRequestFields(codeChallenge: String, state: String, loginHint: String) -> [String: String] {
        [
            "response_type": "code",
            "client_id": ATProtoOAuthConfig.clientID,
            "code_challenge": codeChallenge,
            "code_challenge_method": "S256",
            "redirect_uri": ATProtoOAuthConfig.redirectURI,
            "scope": scopes,
            "state": state,
            "login_hint": loginHint
        ]
    }

    private func pushedAuthorizationRequest(
        metadata: AuthorizationServerMetadata,
        codeChallenge: String,
        state: String,
        loginHint: String
    ) async throws -> String {
        let parURL = metadata.pushedAuthorizationRequestEndpoint
        let fields = Self.parRequestFields(codeChallenge: codeChallenge, state: state, loginHint: loginHint)
        let body = fields
            .map { key, value in "\(Self.formEncode(key))=\(Self.formEncode(value))" }
            .joined(separator: "&")

        var request = URLRequest(url: parURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        /// ATProto auth servers typically answer the first PAR with `401` + `DPoP-Nonce` (`use_dpop_nonce`); retry with a proof that includes the nonce.
        for attempt in 1 ... 3 {
            request.setValue(try await dpop.proof(method: "POST", url: parURL), forHTTPHeaderField: "DPoP")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing PAR response.")
            }
            await dpop.updateNonce(from: http)
            if (200 ..< 300).contains(http.statusCode) {
                return try Self.parsePARSuccess(data: data)
            }
            if Self.shouldRetryDPoPAfterNonceChallenge(http), attempt < 3 {
                continue
            }
            throw SocialWireError.badResponse(Self.describeOAuthFailure(label: "PAR", url: parURL, status: http.statusCode, data: data))
        }
        throw SocialWireError.badResponse("OAuth PAR: exhausted DPoP nonce retries.")
    }

    private static func parsePARSuccess(data: Data) throws -> String {
        try JSONDecoder().decode(PARResponse.self, from: data).requestURI
    }

    /// True when the server is asking for a fresh DPoP proof with the nonce from `DPoP-Nonce` (common on first PAR / token POST).
    private static func shouldRetryDPoPAfterNonceChallenge(_ http: HTTPURLResponse) -> Bool {
        guard http.value(forHTTPHeaderField: "DPoP-Nonce") != nil else { return false }
        return http.statusCode == 400 || http.statusCode == 401
    }

    private struct OAuthErrorJSON: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private static func describeOAuthFailure(label: String, url: URL, status: Int, data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmed = raw.count > 400 ? String(raw.prefix(400)) + "…" : raw
        if let decoded = try? JSONDecoder().decode(OAuthErrorJSON.self, from: data), let err = decoded.error {
            let extra = decoded.errorDescription.map { " — \($0)" } ?? ""
            return "\(label) HTTP \(status) (\(url.host ?? url.absoluteString)): \(err)\(extra)"
        }
        if !trimmed.isEmpty {
            return "\(label) HTTP \(status): \(trimmed)"
        }
        return "\(label) HTTP \(status) (\(url.absoluteString))"
    }

    private static func fetchAuthorizationServerMetadata(pdsURL: URL) async throws -> AuthorizationServerMetadata {
        let protectedResourceURL = pdsURL.appending(path: ".well-known/oauth-protected-resource")
        let protected: OAuthProtectedResourceMetadata = try await fetchJSON(protectedResourceURL)
        guard let issuerString = protected.authorizationServers.first else {
            throw SocialWireError.badResponse("OAuth protected resource metadata missing authorization_servers.")
        }
        guard let issuerURL = URL(string: issuerString) else {
            throw SocialWireError.badResponse("Invalid authorization server issuer URL.")
        }
        let asMetadataURL = issuerURL.appending(path: ".well-known/oauth-authorization-server")
        return try await fetchJSON(asMetadataURL)
    }

    private static func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SocialWireError.badResponse("Request failed for \(url.absoluteString).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func exchangeCode(code: String, verifier: String, tokenEndpoint: URL) async throws -> TokenResponse {
        try await tokenRequest(
            tokenEndpoint: tokenEndpoint,
            fields: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": ATProtoOAuthConfig.redirectURI,
                "client_id": ATProtoOAuthConfig.clientID,
                "code_verifier": verifier
            ]
        )
    }

    private func refreshTokens(refreshToken: String, tokenEndpoint: URL) async throws -> TokenResponse {
        try await tokenRequest(
            tokenEndpoint: tokenEndpoint,
            fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": ATProtoOAuthConfig.clientID
            ]
        )
    }

    private func tokenRequest(tokenEndpoint: URL, fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { key, value in "\(Self.formEncode(key))=\(Self.formEncode(value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        for attempt in 1 ... 3 {
            request.setValue(try await dpop.proof(method: "POST", url: tokenEndpoint), forHTTPHeaderField: "DPoP")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing token response.")
            }
            await dpop.updateNonce(from: http)
            if (200 ..< 300).contains(http.statusCode) {
                return try JSONDecoder().decode(TokenResponse.self, from: data)
            }
            if Self.shouldRetryDPoPAfterNonceChallenge(http), attempt < 3 {
                continue
            }
            throw SocialWireError.badResponse(Self.describeOAuthFailure(label: "Token", url: tokenEndpoint, status: http.statusCode, data: data))
        }
        throw SocialWireError.badResponse("OAuth token: exhausted DPoP nonce retries.")
    }

    private func persist(did: String, pdsURL: URL, tokenEndpoint: URL, tokens: TokenResponse) {
        let next = AuthSession(
            did: did,
            pdsURL: pdsURL,
            tokenEndpoint: tokenEndpoint,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            tokenType: tokens.tokenType,
            expiresAt: Date().addingTimeInterval(tokens.expiresIn ?? 3600)
        )
        session = next
        keychain.set(did, for: "oauth.did")
        keychain.set(pdsURL.absoluteString, for: "oauth.pdsURL")
        keychain.set(tokenEndpoint.absoluteString, for: "oauth.tokenEndpoint")
        keychain.set(tokens.refreshToken, for: "oauth.refreshToken")
        Task {
            let rawKey = await dpop.exportPrivateKey()
            keychain.set(rawKey, for: "oauth.dpopKey")
        }
    }

    private func clearSession() {
        session = nil
        keychain.remove("oauth.did")
        keychain.remove("oauth.pdsURL")
        keychain.remove("oauth.tokenEndpoint")
        keychain.remove("oauth.refreshToken")
        keychain.remove("oauth.dpopKey")
        resetPendingOAuthState()
    }

    private func resetPendingOAuthState() {
        pkceVerifier = nil
        pendingDID = nil
        pendingPDSURL = nil
        pendingTokenEndpoint = nil
        pendingAuthorizationIssuer = nil
        pendingOAuthState = nil
    }

    static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(from verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
