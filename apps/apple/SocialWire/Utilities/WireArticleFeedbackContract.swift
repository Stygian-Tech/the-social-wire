import CryptoKit
import Foundation

enum WireArticleFeedbackContract {
    static func normalizeCanonicalURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil
        else { return nil }

        components.scheme = scheme
        components.fragment = nil
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        return components.url?.absoluteString
    }

    static func recordKey(canonicalURL: String) throws -> String {
        guard let normalized = normalizeCanonicalURL(canonicalURL) else {
            throw SocialWireError.invalidURL
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
