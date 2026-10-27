#if os(iOS)
import Foundation

struct AccountBadgeProfile: Decodable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: URL?
}

#endif
