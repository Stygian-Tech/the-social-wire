import Foundation

/// Resolves OAuth `client_id` and native redirect URI/scheme. Supports a production default plus an optional
/// **Info.plist** override so you can point at a Vercel preview, staging, or any HTTPS URL that serves
/// `ios-client-metadata.json` before production hosts it.
enum ATProtoOAuthConfig {
    /// Set in the app Info.plist (string) to override metadata URL — e.g. a Vercel preview deployment.
    private static let clientIDPlistKey = "ATProtoOAuthClientID"

    /// Production metadata (must stay in sync with `apps/web/public/ios-client-metadata.json` on this host).
    static let defaultClientID = "https://thesocialwire.app/ios-client-metadata.json"

    static var clientID: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: clientIDPlistKey) as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, URL(string: trimmed)?.host != nil {
                return trimmed
            }
        }
        return defaultClientID
    }

    /// Userinfo callback URL for `ASWebAuthenticationSession` (host derived from `client_id`).
    static var callbackURLScheme: String {
        nativeRedirectPair(forClientID: clientID).scheme
    }

    /// Authorization `redirect_uri` (must appear in the metadata document at `client_id`).
    static var redirectURI: String {
        nativeRedirectPair(forClientID: clientID).redirectURI
    }

    /// Reversed domain labels for ATProto native clients, e.g. `thesocialwire.app` → `app.thesocialwire`.
    static func nativeURLScheme(forHost host: String) -> String {
        host.split(separator: ".").reversed().joined(separator: ".")
    }

    /// `(scheme, redirectURI)` for a metadata URL string (used by tests and redirects).
    static func nativeRedirectPair(forClientID clientIDString: String) -> (scheme: String, redirectURI: String) {
        guard let host = URL(string: clientIDString)?.host, !host.isEmpty else {
            let fallback = nativeURLScheme(forHost: "thesocialwire.app")
            return (fallback, "\(fallback):/oauth/callback")
        }
        let scheme = nativeURLScheme(forHost: host)
        return (scheme, "\(scheme):/oauth/callback")
    }
}
