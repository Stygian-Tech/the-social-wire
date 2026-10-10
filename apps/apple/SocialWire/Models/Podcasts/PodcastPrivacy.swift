import Foundation

/// Keeps authenticated media and credential-bearing URLs out of public records and processing jobs.
enum PodcastPrivacy {
    nonisolated static func permitsPublicURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil else { return false }
        let privateKeys = ["token", "password", "secret", "auth", "authorization", "credential", "signature", "apikey", "accesskey", "subscriber", "subscriptionkey", "feedkey"]
        return !(components.queryItems ?? []).contains { item in
            let key = item.name.lowercased().filter(\.isLetter)
            return privateKeys.contains(where: { key.contains($0) })
        }
    }
}
