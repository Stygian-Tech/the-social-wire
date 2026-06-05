import Foundation

/// L@tr read-later gateway transport and DPoP proof targets.
enum LatrGatewayEnvironment {
    private static let testProofBaseURLString = "https://api.testing.latr.link"
    private static let prodProofBaseURLString = "https://api.latr.link"

    static let latrGatewayDPoPHeaderName = "X-Latr-Gateway-DPoP"

    /// External L@tr Gateway URL used when minting `X-Latr-Gateway-DPoP` proofs (`htu`).
    static var proofBaseURLString: String {
        if let configured = ProcessInfo.processInfo.environment["LATR_GATEWAY_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        #if DEBUG || SOCIALWIRE_TESTING_API
        return testProofBaseURLString
        #else
        return prodProofBaseURLString
        #endif
    }

    static var proofBaseURL: URL {
        guard let url = URL(string: proofBaseURLString) else {
            preconditionFailure("Invalid L@tr gateway proof base URL.")
        }
        return url
    }

    /// Where HTTP requests are sent. Production iOS uses the Social Wire Gateway proxy.
    static var transportBaseURL: URL {
        if usesDirectExternalGateway {
            return proofBaseURL
        }
        return SocialWireAPIEnvironment.baseURL
    }

    /// Debug-only bypass of the Social Wire proxy (requires local L@tr credentials).
    static var usesDirectExternalGateway: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOCIALWIRE_LATR_DIRECT"] == "1"
        #else
        return false
        #endif
    }

    /// Split developer credentials — only used with `SOCIALWIRE_LATR_DIRECT=1`.
    static var developerClientId: String? {
        guard usesDirectExternalGateway else { return nil }
        return trimmedEnv("LATR_GATEWAY_CLIENT_ID")
    }

    static var developerApiKey: String? {
        guard usesDirectExternalGateway else { return nil }
        return trimmedEnv("LATR_GATEWAY_API_KEY")
    }

    static var officialClientCredential: String? {
        guard usesDirectExternalGateway else { return nil }
        return trimmedEnv("LATR_GATEWAY_CLIENT_CREDENTIAL")
    }

    private static func trimmedEnv(_ key: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}
