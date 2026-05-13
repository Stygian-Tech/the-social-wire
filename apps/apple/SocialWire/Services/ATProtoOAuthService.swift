import Foundation
import AuthenticationServices
import SwiftUI
import CryptoKit

/// Manages ATProto OAuth PKCE + DPoP authentication.
///
/// Flow:
/// 1. `signIn(handle:)` → resolve DID → fetch PDS metadata → build auth URL → `ASWebAuthenticationSession`
/// 2. Callback URL → exchange code for tokens → store refresh token in Keychain
/// 3. Access token kept in memory; `refreshIfNeeded()` is called before each API request
@MainActor
final class ATProtoOAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    @Published private(set) var session: AuthSession?

    private let keychain = KeychainWrapper()
    private let plcURL = URL(string: ProcessInfo.processInfo.environment["ATPROTO_PLC_URL"] ?? "https://plc.directory")!
    private let clientID: String = {
        ProcessInfo.processInfo.environment["ATPROTO_CLIENT_ID"] ?? "https://thesocialwire.com/client-metadata.json"
    }()

    // PKCE state stored between authorize and callback
    private var pkceVerifier: String?
    private var pendingDID: String?
    private var pendingPDSURL: URL?

    // ── Public API ────────────────────────────────────────────────────────────

    /// Attempts to restore a previously saved session on app launch.
    func restoreSession() async {
        guard
            let did = keychain.string(forKey: "atproto.did"),
            let refreshToken = keychain.string(forKey: "atproto.refreshToken"),
            let pdsURLString = keychain.string(forKey: "atproto.pdsURL"),
            let pdsURL = URL(string: pdsURLString)
        else { return }

        do {
            let tokens = try await refreshTokens(refreshToken: refreshToken, pdsURL: pdsURL)
            session = AuthSession(
                did: did,
                pdsURL: pdsURL,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )
            keychain.set(tokens.refreshToken, forKey: "atproto.refreshToken")
        } catch {
            // Refresh failed — require re-login
            clearKeychain()
        }
    }

    /// Initiates the sign-in flow via ASWebAuthenticationSession.
    func signIn(handle: String) async throws {
        // 1. Resolve handle → DID → PDS URL
        let did = try await resolveDID(handle: handle)
        let pdsURL = try await resolvePDSURL(did: did)

        // 2. Generate PKCE challenge
        let verifier = generateCodeVerifier()
        let challenge = codeChallenge(from: verifier)
        self.pkceVerifier = verifier
        self.pendingDID = did
        self.pendingPDSURL = pdsURL

        // 3. Build authorization URL
        let authURL = try buildAuthURL(
            pdsURL: pdsURL,
            challenge: challenge,
            state: did
        )

        // 4. Present ASWebAuthenticationSession
        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "thesocialwire"
            ) { url, error in
                if let error { cont.resume(throwing: error) }
                else if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: OAuthError.unknownCallbackError) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        // 5. Exchange code for tokens
        try await handleCallbackURL(callbackURL)
    }

    /// Handles the callback URL from the OAuth redirect.
    func handleCallbackURL(_ url: URL) async {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            let verifier = pkceVerifier,
            let did = pendingDID,
            let pdsURL = pendingPDSURL
        else { return }

        do {
            let tokens = try await exchangeCode(
                code: code,
                verifier: verifier,
                pdsURL: pdsURL
            )

            session = AuthSession(
                did: did,
                pdsURL: pdsURL,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )

            // Persist to Keychain
            keychain.set(did, forKey: "atproto.did")
            keychain.set(tokens.refreshToken, forKey: "atproto.refreshToken")
            keychain.set(pdsURL.absoluteString, forKey: "atproto.pdsURL")
        } catch {
            print("[ATProtoOAuthService] Callback error: \(error)")
        }

        pkceVerifier = nil
        pendingDID = nil
        pendingPDSURL = nil
    }

    /// Signs the user out and clears all stored credentials.
    func signOut() async {
        session = nil
        clearKeychain()
    }

    /// Refreshes the access token if it is expired or about to expire.
    func refreshIfNeeded() async throws {
        guard var current = session else { throw OAuthError.notAuthenticated }
        // Phase 1: always refresh on demand (TODO: check expiry claim)
        let tokens = try await refreshTokens(
            refreshToken: current.refreshToken,
            pdsURL: current.pdsURL
        )
        current.accessToken = tokens.accessToken
        current.refreshToken = tokens.refreshToken
        session = current
        keychain.set(tokens.refreshToken, forKey: "atproto.refreshToken")
    }

    // ── ASWebAuthenticationPresentationContextProviding ───────────────────────

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }

    // ── Private ───────────────────────────────────────────────────────────────

    private func resolveDID(handle: String) async throws -> String {
        let normalised = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let base = (ProcessInfo.processInfo.environment["ATPROTO_APPVIEW_PUBLIC"] ?? "https://public.api.bsky.app")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedBase = base
        while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
        var c = URLComponents(string: "\(trimmedBase)/xrpc/com.atproto.identity.resolveHandle")!
        c.queryItems = [URLQueryItem(name: "handle", value: normalised)]
        guard let url = c.url else { throw OAuthError.didResolutionFailed }
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONDecoder().decode([String: String].self, from: data)
        guard let did = json["did"] else { throw OAuthError.didResolutionFailed }
        return did
    }

    private func resolvePDSURL(did: String) async throws -> URL {
        let url = plcURL.appendingPathComponent(did)
        let (data, _) = try await URLSession.shared.data(from: url)
        let doc = try JSONDecoder().decode(DIDDocument.self, from: data)
        guard
            let serviceEntry = doc.service?.first(where: {
                $0.type == "AtprotoPersonalDataServer" || $0.id.hasSuffix("#atproto_pds")
            }),
            let pdsURL = URL(string: serviceEntry.serviceEndpoint)
        else { throw OAuthError.pdsResolutionFailed }
        return pdsURL
    }

    private func buildAuthURL(pdsURL: URL, challenge: String, state: String) throws -> URL {
        var components = URLComponents(url: pdsURL.appendingPathComponent("/oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "thesocialwire://oauth/callback"),
            URLQueryItem(name: "scope", value: "atproto"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw OAuthError.invalidURL }
        return url
    }

    private func exchangeCode(code: String, verifier: String, pdsURL: URL) async throws -> TokenPair {
        let tokenURL = pdsURL.appendingPathComponent("/oauth/token")
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=thesocialwire://oauth/callback",
            "client_id=\(clientID)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed
        }
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenPair(accessToken: json.access_token, refreshToken: json.refresh_token)
    }

    private func refreshTokens(refreshToken: String, pdsURL: URL) async throws -> TokenPair {
        let tokenURL = pdsURL.appendingPathComponent("/oauth/token")
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(clientID)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.tokenRefreshFailed
        }
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenPair(accessToken: json.access_token, refreshToken: json.refresh_token)
    }

    private func clearKeychain() {
        keychain.remove(forKey: "atproto.did")
        keychain.remove(forKey: "atproto.refreshToken")
        keychain.remove(forKey: "atproto.pdsURL")
    }

    // ── PKCE helpers ──────────────────────────────────────────────────────────

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func codeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncoded()
    }
}

// ── Supporting types ──────────────────────────────────────────────────────────

struct AuthSession {
    let did: String
    let pdsURL: URL
    var accessToken: String
    var refreshToken: String
}

private struct TokenPair {
    let accessToken: String
    let refreshToken: String
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
}

private struct DIDDocument: Decodable {
    let service: [ServiceEntry]?

    struct ServiceEntry: Decodable {
        let id: String
        let type: String
        let serviceEndpoint: String
    }
}

enum OAuthError: Error, LocalizedError {
    case didResolutionFailed
    case pdsResolutionFailed
    case invalidURL
    case tokenExchangeFailed
    case tokenRefreshFailed
    case notAuthenticated
    case unknownCallbackError

    var errorDescription: String? {
        switch self {
        case .didResolutionFailed: "Could not resolve your handle to a DID. Check the handle and try again."
        case .pdsResolutionFailed: "Could not find your ATProto PDS."
        case .invalidURL: "Invalid authorization URL."
        case .tokenExchangeFailed: "Failed to exchange the authorization code for tokens."
        case .tokenRefreshFailed: "Failed to refresh your session. Please sign in again."
        case .notAuthenticated: "Not signed in."
        case .unknownCallbackError: "Unknown error in the authorization callback."
        }
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
