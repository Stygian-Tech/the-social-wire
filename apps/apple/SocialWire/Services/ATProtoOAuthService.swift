import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import SwiftUI

/// Uses **`@Observable`** so views that read **`session`** directly transition when authentication changes.
@MainActor
@Observable
final class ATProtoOAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TheSocialWire", category: "OAuth")
    private static let persistedSessionKey = "oauth.session.v2"

    private struct PersistedSession: Codable {
        let session: AuthSession
        let dpopPrivateKey: String
        let clientID: String?
    }

    static let scopes = [
        "atproto",
        "repo:app.thesocialwire.readState?action=create&action=update",
        "repo:app.thesocialwire.readStateChunk?action=create&action=update&action=delete",
        "repo:app.thesocialwire.folder?action=create&action=update&action=delete",
        "repo:app.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
        "repo:app.thesocialwire.preferences?action=create&action=update&action=delete",
        "repo:com.thesocialwire.folder?action=create&action=update&action=delete",
        "repo:com.thesocialwire.publicationPrefs?action=create&action=update&action=delete",
        "repo:com.thesocialwire.preferences?action=create&action=update&action=delete",
        "include:app.bsky.authCreatePosts?aud=did:web:api.bsky.app%23bsky_appview",
        "include:app.bsky.authDeleteContent?aud=did:web:api.bsky.app%23bsky_appview",
        "rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23bsky_appview",
        "rpc:app.bsky.graph.getBlocks?aud=did:web:api.bsky.app%23bsky_appview",
        "rpc:app.bsky.graph.getMutes?aud=did:web:api.bsky.app%23bsky_appview",
        "rpc:app.bsky.graph.getListMutes?aud=did:web:api.bsky.app%23bsky_appview",
        "rpc:app.bsky.graph.getListBlocks?aud=did:web:api.bsky.app%23bsky_appview",
        "rpc:app.bsky.graph.getList?aud=did:web:api.bsky.app%23bsky_appview",
        "repo:app.bsky.feed.like?action=create",
        "repo:app.bsky.feed.repost?action=create",
        "repo:community.lexicon.bookmarks.bookmark?action=create&action=update&action=delete",
        "include:link.latr.authFull",
        "repo:link.latr.saved.external?action=delete",
        "repo:link.latr.saved.item?action=delete",
        "repo:com.latr.saved.external?action=delete",
        "repo:com.latr.saved.item?action=delete",
        "repo:network.cosmik.card?action=create&action=update&action=delete",
        "repo:network.cosmik.collection?action=create&action=update&action=delete",
        "repo:network.cosmik.collectionLink?action=create&action=update&action=delete",
        "repo:network.cosmik.collectionLinkRemoval?action=create&action=update&action=delete",
        "repo:network.cosmik.connection?action=create&action=update&action=delete",
        "repo:app.thesocialwire.wireFeedback?action=create&action=update&action=delete",
        "include:site.standard.authSocial",
        "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
        "include:app.userinput.authFull",
        "blob:*/*",
        "repo:site.standard.graph.subscription?action=create&action=update&action=delete",
        // Quote/reply edits use putRecord; create/delete are covered by the Bluesky permission sets.
        // NOTE: the published client metadata at `/ios-client-metadata.json` must list these same
        // scopes or the authorization server will reject the broadened request (returns 403 on write).
        "repo:app.bsky.feed.post?action=update"
    ].joined(separator: " ")

    private(set) var session: AuthSession? {
        didSet {
            sessionChangeHandler?(session)
        }
    }
    private(set) var reauthorizationRequired = false
    @ObservationIgnored private var sessionChangeHandler: ((AuthSession?) -> Void)?

    // Existing sessions remain usable until the viewer explicitly opts into PDS history.
    static let pdsReadStateScopes: Set<String> = [
        "repo:app.thesocialwire.readState?action=create&action=update",
        "repo:app.thesocialwire.readStateChunk?action=create&action=update",
    ]

    static let requiredFeatureScopes: Set<String> = [
        "repo:app.thesocialwire.wireFeedback?action=create&action=update&action=delete",
        "include:site.standard.authSocial",
        "include:app.userinput.authFull",
        "blob:*/*",
        "repo:network.cosmik.card?action=create&action=update&action=delete",
        "repo:network.cosmik.collection?action=create&action=update&action=delete",
        "repo:network.cosmik.collectionLink?action=create&action=update&action=delete",
        "repo:network.cosmik.collectionLinkRemoval?action=create&action=update&action=delete",
        "repo:network.cosmik.connection?action=create&action=update&action=delete",
    ]

    let dpop = DPoPService()
    private let keychain: any OAuthSessionStoring
    @ObservationIgnored private let tokenTransport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    @ObservationIgnored private var refreshTask: Task<AuthSession, Error>?
    @ObservationIgnored private var sessionRevision = UUID()
    private let resolver = ATProtoResolver()

    private var pkceVerifier: String?
    private var pendingDID: String?
    private var pendingPDSURL: URL?
    private var pendingTokenEndpoint: URL?
    private var pendingAuthorizationIssuer: String?
    private var pendingOAuthState: String?
    private var webAuthenticationSession: ASWebAuthenticationSession?

    init(
        keychain: any OAuthSessionStoring = KeychainStore(),
        tokenTransport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) {
        self.keychain = keychain
        self.tokenTransport = tokenTransport
        super.init()
    }

    func setSessionChangeHandler(_ handler: @escaping (AuthSession?) -> Void) {
        sessionChangeHandler = handler
        handler(session)
    }

    func restoreSession() async {
        Self.logger.debug("OAuth restore started")
        if let persisted = persistedSession() {
            await restore(persisted)
            return
        }

        guard
            let did = keychain.string(for: "oauth.did"),
            let refreshToken = keychain.string(for: "oauth.refreshToken"),
            let pdsString = keychain.string(for: "oauth.pdsURL"),
            let pdsURL = URL(string: pdsString),
            let tokenString = keychain.string(for: "oauth.tokenEndpoint"),
            let tokenEndpoint = URL(string: tokenString),
            let rawKey = keychain.string(for: "oauth.dpopKey")
        else {
            Self.logger.debug("OAuth restore found no complete persisted session")
            clearSession()
            return
        }

        let restored = AuthSession(
            did: did, pdsURL: pdsURL, tokenEndpoint: tokenEndpoint,
            accessToken: keychain.string(for: "oauth.accessToken") ?? "",
            refreshToken: refreshToken,
            tokenType: keychain.string(for: "oauth.tokenType") ?? "DPoP",
            scope: keychain.string(for: "oauth.scope"),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(keychain.string(for: "oauth.expiresAt") ?? "") ?? 0)
        )
        await restore(PersistedSession(session: restored, dpopPrivateKey: rawKey,
            clientID: keychain.string(for: "oauth.clientID")))
    }

    private func persistedSession() -> PersistedSession? {
        guard let encoded = keychain.string(for: Self.persistedSessionKey),
              let data = Data(base64Encoded: encoded),
              let persisted = try? JSONDecoder().decode(PersistedSession.self, from: data)
        else { return nil }
        return persisted
    }

    private func restore(_ persisted: PersistedSession) async {
        let restored = persisted.session
        // Never relabel a Beta refresh token as a Production token. Older records can migrate
        // only when they contain an explicit client_id claim; opaque/unbound records reauthorize.
        guard Self.persistedClientID(stored: persisted.clientID, accessToken: restored.accessToken)
                == ATProtoOAuthConfig.clientID else {
            requireReauthorization()
            return
        }
        let revision = sessionRevision
        await dpop.replacePrivateKey(base64: persisted.dpopPrivateKey)
        guard sessionRevision == revision else { return }
        persistSessionRecord(restored, dpopPrivateKey: persisted.dpopPrivateKey)
        session = restored
        guard restored.expiresAt.timeIntervalSinceNow <= 60 else { return }
        do {
            _ = try await refreshedSession(rejected: restored)
        } catch {
            // Keep the bound session on offline/5xx failures so the next request can retry.
            Self.logger.error("OAuth restore refresh failed")
        }
    }

    nonisolated static func persistedClientID(stored: String?, accessToken: String) -> String? {
        if let stored, !stored.isEmpty { return stored }
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = claims["client_id"] as? String, !clientID.isEmpty else { return nil }
        // This is a migration hint from credentials already stored on this device, not token
        // verification. The current issuer and Gateway still validate every authenticated call.
        return clientID
    }

    func signIn(handle: String) async throws {
        Self.logger.debug("OAuth sign-in started")
        sessionRevision = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        reauthorizationRequired = false
        let did = try await resolver.resolveDID(handleOrDID: handle)
        let pdsURL = try await resolver.resolvePDSURL(did: did)
        Self.logger.debug("OAuth identity resolved; PDS origin is \(pdsURL.scheme ?? "unknown", privacy: .public)://\(pdsURL.host ?? "unknown", privacy: .public)")
        let asMetadata = try await Self.fetchAuthorizationServerMetadata(pdsURL: pdsURL)
        Self.logger.debug("OAuth authorization metadata loaded from issuer \(asMetadata.issuer, privacy: .public)")

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
        Self.logger.debug("OAuth PAR succeeded; starting web authentication session")

        do {
            let callbackURL: URL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let completion: @Sendable (URL?, Error?) -> Void = { url, error in
                    Task { @MainActor in
                        self.webAuthenticationSession = nil
                        if let error {
                            Self.logger.error("OAuth web session completed with error: \(error.localizedDescription, privacy: .public)")
                            continuation.resume(throwing: error)
                        } else if let url {
                            let callbackKeys = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                .queryItems?
                                .map(\.name)
                                .sorted()
                                .joined(separator: ", ") ?? "none"
                            Self.logger.debug("OAuth web session returned a callback containing keys: \(callbackKeys, privacy: .public)")
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(throwing: SocialWireError.badResponse("OAuth callback did not include a URL."))
                        }
                    }
                }
                let webSession = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: ATProtoOAuthConfig.callbackURLScheme,
                    completionHandler: completion
                )
                webSession.presentationContextProvider = self
                webSession.prefersEphemeralWebBrowserSession = false
                webAuthenticationSession = webSession
                guard webSession.start() else {
                    webAuthenticationSession = nil
                    continuation.resume(throwing: SocialWireError.badResponse("Could not start the OAuth browser session."))
                    return
                }
            }
            try await handleCallbackURL(callbackURL)
            Self.logger.notice("OAuth sign-in completed successfully")
        } catch {
            Self.logger.error("OAuth sign-in failed: \(error.localizedDescription, privacy: .public)")
            webAuthenticationSession?.cancel()
            webAuthenticationSession = nil
            resetPendingOAuthState()
            throw error
        }
    }

    private func handleCallbackURL(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SocialWireError.badResponse("Invalid OAuth callback URL.")
        }
        let queryItems = components.queryItems ?? []
        let query = Dictionary(
            queryItems.map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )

        if let oauthError = query["error"], !oauthError.isEmpty {
            let desc = query["error_description"] ?? oauthError
            resetPendingOAuthState()
            if Self.isOAuthCancellation(code: oauthError, description: desc) {
                throw CancellationError()
            }
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

        let revision = sessionRevision
        let tokens = try await exchangeCode(code: code, verifier: verifier, tokenEndpoint: tokenEndpoint)
        guard sessionRevision == revision else { throw CancellationError() }
        await persist(did: did, pdsURL: pdsURL, tokenEndpoint: tokenEndpoint,
            tokens: tokens, expectedRevision: revision)
        guard sessionRevision == revision else { throw CancellationError() }
        resetPendingOAuthState()
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let error = error as NSError
        let browserCancelled = error.domain == ASWebAuthenticationSessionError.errorDomain
            && error.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
        let requestCancelled = error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled
        let cocoaCancelled = error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.userCancelled.rawValue
        if browserCancelled || requestCancelled || cocoaCancelled {
            return true
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isUserCancellation(underlyingError)
        }
        return false
    }

    static func isOAuthCancellation(code: String, description: String?) -> Bool {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["access_denied", "cancelled", "canceled"].contains(normalizedCode) {
            return true
        }

        let normalizedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedDescription == "cancelled" || normalizedDescription == "canceled"
    }

    func signOut() {
        clearSession()
        reauthorizationRequired = false
    }

    func validSession() async throws -> AuthSession {
        guard let current = session else { throw SocialWireError.notAuthenticated }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current }
        return try await refreshedSession(rejected: current)
    }

    /// Coalesce expired-token and rejected-token recovery. A late response cannot replace a
    /// different login or resurrect credentials after Sign Out.
    func refreshedSession(rejected: AuthSession) async throws -> AuthSession {
        guard let current = session, current.did == rejected.did else {
            throw SocialWireError.notAuthenticated
        }
        if current.accessToken != rejected.accessToken { return current }
        if let refreshTask { return try await refreshTask.value }
        let revision = sessionRevision
        let task = Task<AuthSession, Error> { @MainActor in
            do {
                let tokens = try await self.refreshTokens(
                    refreshToken: current.refreshToken, tokenEndpoint: current.tokenEndpoint)
                guard self.sessionRevision == revision else { throw CancellationError() }
                await self.persist(did: current.did, pdsURL: current.pdsURL,
                    tokenEndpoint: current.tokenEndpoint, tokens: tokens, expectedRevision: revision)
                guard self.sessionRevision == revision, let session = self.session else {
                    throw CancellationError()
                }
                return session
            } catch {
                if self.sessionRevision == revision, error is OAuthCredentialsRejected {
                    self.requireReauthorization()
                    throw SocialWireError.notAuthenticated
                }
                throw error
            }
        }
        refreshTask = task
        defer { if sessionRevision == revision { refreshTask = nil } }
        return try await task.value
    }

    func invalidateSessionAfterUnauthorizedResponse(rejected: AuthSession) {
        guard session?.did == rejected.did, session?.accessToken == rejected.accessToken else { return }
        requireReauthorization()
    }

    private func requireReauthorization() {
        clearSession()
        reauthorizationRequired = true
    }

    private struct OAuthCredentialsRejected: Error {}

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession always invokes this on the main thread, so the main-actor
        // anchor creation is safe to assume isolated here.
        MainActor.assumeIsolated { ASPresentationAnchor() }
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
            Self.logger.debug("OAuth PAR attempt \(attempt) returned HTTP \(http.statusCode); nonce challenge: \(http.value(forHTTPHeaderField: "DPoP-Nonce") != nil)")
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
            let (data, response) = try await tokenTransport(request)
            guard let http = response as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing token response.")
            }
            Self.logger.debug("OAuth token attempt \(attempt) returned HTTP \(http.statusCode); nonce challenge: \(http.value(forHTTPHeaderField: "DPoP-Nonce") != nil)")
            await dpop.updateNonce(from: http)
            if (200 ..< 300).contains(http.statusCode) {
                return try JSONDecoder().decode(TokenResponse.self, from: data)
            }
            if Self.shouldRetryDPoPAfterNonceChallenge(http), attempt < 3 {
                continue
            }
            if [400, 401].contains(http.statusCode),
               let failure = try? JSONDecoder().decode(OAuthErrorJSON.self, from: data),
               ["invalid_grant", "invalid_client", "unauthorized_client"].contains(failure.error ?? "") {
                throw OAuthCredentialsRejected()
            }
            throw SocialWireError.badResponse(Self.describeOAuthFailure(label: "Token", url: tokenEndpoint, status: http.statusCode, data: data))
        }
        throw SocialWireError.badResponse("OAuth token: exhausted DPoP nonce retries.")
    }

    private func persist(did: String, pdsURL: URL, tokenEndpoint: URL, tokens: TokenResponse,
                         expectedRevision: UUID) async {
        let next = AuthSession(
            did: did,
            pdsURL: pdsURL,
            tokenEndpoint: tokenEndpoint,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            tokenType: tokens.tokenType,
            scope: tokens.scope ?? keychain.string(for: "oauth.scope") ?? Self.scopes,
            expiresAt: Date().addingTimeInterval(tokens.expiresIn ?? 3600)
        )
        let rawKey = await dpop.exportPrivateKey()
        guard sessionRevision == expectedRevision else { return }
        persistSessionRecord(next, dpopPrivateKey: rawKey)
        keychain.set(rawKey, for: "oauth.dpopKey")
        keychain.set(ATProtoOAuthConfig.clientID, for: "oauth.clientID")
        keychain.set(did, for: "oauth.did")
        keychain.set(pdsURL.absoluteString, for: "oauth.pdsURL")
        keychain.set(tokenEndpoint.absoluteString, for: "oauth.tokenEndpoint")
        keychain.set(tokens.refreshToken, for: "oauth.refreshToken")
        // Persist the access token + expiry so a warm launch can reuse a still-valid token instead
        // of forcing a token-refresh round-trip in restoreSession().
        keychain.set(next.accessToken, for: "oauth.accessToken")
        keychain.set(next.tokenType, for: "oauth.tokenType")
        keychain.set(next.scope ?? Self.scopes, for: "oauth.scope")
        keychain.set(String(next.expiresAt.timeIntervalSince1970), for: "oauth.expiresAt")
        session = next
        Self.logger.notice("OAuth session established; access token expires in \(Int(next.expiresAt.timeIntervalSinceNow)) seconds")
    }

    private func persistSessionRecord(_ session: AuthSession, dpopPrivateKey: String) {
        guard let data = try? JSONEncoder().encode(
            PersistedSession(session: session, dpopPrivateKey: dpopPrivateKey, clientID: ATProtoOAuthConfig.clientID)
        ) else { return }
        keychain.set(data.base64EncodedString(), for: Self.persistedSessionKey)
    }

    private func clearSession() {
        sessionRevision = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        if session != nil {
            Self.logger.notice("OAuth session cleared")
        }
        session = nil
        keychain.remove("oauth.did")
        keychain.remove("oauth.pdsURL")
        keychain.remove("oauth.tokenEndpoint")
        keychain.remove("oauth.refreshToken")
        keychain.remove("oauth.accessToken")
        keychain.remove("oauth.tokenType")
        keychain.remove("oauth.scope")
        keychain.remove("oauth.expiresAt")
        keychain.remove("oauth.dpopKey")
        keychain.remove(Self.persistedSessionKey)
        keychain.remove("oauth.clientID")
        resetPendingOAuthState()
    }

    static func hasPDSReadStateScopes(_ rawScope: String?) -> Bool {
        hasReadStateActions(rawScope, collection: "app.thesocialwire.readState", required: ["create", "update"])
            && hasReadStateActions(rawScope, collection: "app.thesocialwire.readStateChunk", required: ["create", "update"])
    }

    /// Cleanup remains optional; lacking delete must not block normal history writes.
    static func hasPDSReadStateCleanupScopes(_ rawScope: String?) -> Bool {
        hasPDSReadStateScopes(rawScope)
            && hasReadStateActions(rawScope, collection: "app.thesocialwire.readStateChunk", required: ["delete"])
    }

    private static func hasReadStateActions(_ rawScope: String?, collection: String, required: Set<String>) -> Bool {
        guard let rawScope else { return false }
        let prefix = "repo:\(collection)?"
        var actions = Set<String>()
        for token in rawScope.split(whereSeparator: { $0.isWhitespace }) where token.hasPrefix(prefix) {
            let parameters = token.dropFirst(prefix.count).split(separator: "&")
            // Unknown constraints cannot be treated as an unrestricted permission.
            guard !parameters.isEmpty, parameters.allSatisfy({ $0.hasPrefix("action=") }) else { continue }
            actions.formUnion(parameters.map { String($0.dropFirst("action=".count)) })
        }
        return required.isSubset(of: actions)
    }

    static func hasRequiredFeatureScopes(_ rawScope: String?) -> Bool {
        guard let rawScope else { return false }
        let granted = Set(rawScope.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        return requiredFeatureScopes.isSubset(of: granted)
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
