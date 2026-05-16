import Foundation

enum PublicURLNormalizer {
    static func normalizeHttpURLToHTTPS(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let candidate: String
        if trimmed.lowercased().hasPrefix("http://") {
            candidate = "https://" + trimmed.dropFirst("http://".count)
        } else if trimmed.lowercased().hasPrefix("https://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate) else { return candidate }
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.filter { !$0.name.lowercased().hasPrefix("bridge") }
            if components.queryItems?.isEmpty == true {
                components.queryItems = nil
            }
        }
        return components.url?.absoluteString ?? candidate
    }

    static func sanitizeEmbedURL(_ raw: String) -> String {
        normalizeHttpURLToHTTPS(raw)
    }

    static func isBridgyPDS(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host == "atproto.brid.gy" || host.hasSuffix(".atproto.brid.gy")
    }
}
