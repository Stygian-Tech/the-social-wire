import Foundation

/// Base URL for L@tr Link gateway mutations (save/archive/delete enrichment).
enum LatrGatewayEnvironment {
    private static let localBaseURLString = "http://127.0.0.1:8080"
    private static let devBaseURLString = "https://latr-link-dev-gateway.fly.dev"
    private static let prodBaseURLString = "https://latr-link-prod-gateway.fly.dev"

    static var baseURLString: String {
        if let configured = ProcessInfo.processInfo.environment["LATR_GATEWAY_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        #if DEBUG || SOCIALWIRE_TESTING_API
        return devBaseURLString
        #else
        return prodBaseURLString
        #endif
    }

    static var baseURL: URL {
        guard let url = URL(string: baseURLString) else {
            preconditionFailure("Invalid L@tr gateway base URL.")
        }
        return url
    }

    /// Base64 official client credential (`social-wire` in gateway env). Optional in local dev.
    static var officialClientCredential: String? {
        let raw = ProcessInfo.processInfo.environment["LATR_GATEWAY_CLIENT_CREDENTIAL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    static let officialClientHeaderName = "X-Latr-Official-Client"
}
