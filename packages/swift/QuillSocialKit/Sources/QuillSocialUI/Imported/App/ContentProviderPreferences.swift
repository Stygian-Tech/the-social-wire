#if os(iOS)
import Foundation

enum ContentProviderPreferences {
    static let blueskyProxy = "did:web:api.bsky.app#bsky_appview"
    static let blackskyProxy = "did:web:api.blacksky.community#bsky_appview"

    private static let proxyKey = "content-provider-proxy"
    private static let blueskyModerationKey = "includes-bluesky-moderation"
    private static let additionalLabelersKey = "additional-labeler-dids"

    static var activeProxy: String {
        UserDefaults.standard.string(forKey: proxyKey) ?? blueskyProxy
    }

    static var includesBlueskyModeration: Bool {
        guard UserDefaults.standard.object(forKey: blueskyModerationKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: blueskyModerationKey)
    }

    static var additionalLabelerDIDs: [String] {
        UserDefaults.standard.stringArray(forKey: additionalLabelersKey) ?? []
    }

    static func saveProvider(proxy: String) {
        UserDefaults.standard.set(proxy, forKey: proxyKey)
    }

    static func saveModeration(includesBluesky: Bool, additionalLabelerDIDs: [String]) {
        UserDefaults.standard.set(includesBluesky, forKey: blueskyModerationKey)
        UserDefaults.standard.set(additionalLabelerDIDs, forKey: additionalLabelersKey)
    }

    static func proxy(forDomain value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let host: String
        if let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
           let resolvedHost = url.host(), resolvedHost.contains(".") {
            host = resolvedHost
        } else {
            return nil
        }
        return "did:web:\(host)#bsky_appview"
    }
}

#endif
