import Foundation

/// Resolves OAuth `client_id` and native redirect URI/scheme (`SocialWireAPIEnvironment`).
///
/// **[ATProto]** For discoverable native client metadata (`client_id` is an HTTPS URL), the custom URL scheme /
/// **`redirect_uri`** must be **`client_id` host labels reversed**, e.g. `api.testing.thesocialwire.app`
/// → `app.thesocialwire.testing.api`.
enum ATProtoOAuthConfig {
    /// Set in Info.plist (string) to override metadata URL — tunnels, previews, alternate hosts.
    private static let clientIDPlistKey = "ATProtoOAuthClientID"

    /// Fallback host when **`client_id`** cannot be parsed (should not happen with valid plist default).
    private static let redirectHostFallback = "thesocialwire.app"

    /// Default **`client_id`** (`GET` Swift API **`/ios-client-metadata.json`**).
    static var defaultClientID: String {
        SocialWireAPIEnvironment.iosClientMetadataURL.absoluteString
    }

    static var clientID: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: clientIDPlistKey) as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, URL(string: trimmed)?.host != nil {
                return trimmed
            }
        }
        return defaultClientID
    }

    /// Single-slash native callback scheme for **`ASWebAuthenticationSession`**, reversed FQDN of **`URL(client_id)?.host`**.
    static var callbackURLScheme: String {
        nativeRedirectPair(forClientID: clientID).scheme
    }

    /// Authorization **`redirect_uri`** (must match **`redirect_uris`** in discovery doc at **`client_id`**).
    static var redirectURI: String {
        nativeRedirectPair(forClientID: clientID).redirectURI
    }

    /// Reversed domain labels (ATProto native), e.g. `thesocialwire.app` → **`app.thesocialwire`**.
    static func nativeURLScheme(forHost host: String) -> String {
        host.split(separator: ".").reversed().joined(separator: ".")
    }

    /// Pair matching **`IosOAuthClientMetadata`** / **`ATProto`** rules for **`client_id` URL**.
    static func nativeRedirectPair(forClientID clientIDString: String) -> (scheme: String, redirectURI: String) {
        guard let host = URL(string: clientIDString)?.host, !host.isEmpty else {
            let scheme = nativeURLScheme(forHost: redirectHostFallback)
            return (scheme, "\(scheme):/oauth/callback")
        }
        let scheme = nativeURLScheme(forHost: host)
        return (scheme, "\(scheme):/oauth/callback")
    }
}
