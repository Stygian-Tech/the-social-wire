import ATProtoCore
import Foundation

/// Web post links remain useful outside AT Protocol-aware clients.
public enum PostShareURL {
    public static func url(for uri: String) -> URL? {
        guard !uri.contains("?"), !uri.contains("#"),
              let reference = try? ATURI(uri),
              reference.collection?.description == "app.bsky.feed.post",
              let key = reference.recordKey else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "bsky.app"
        components.path = "/profile/\(reference.authority)/post/\(key)"
        return components.url
    }
}
