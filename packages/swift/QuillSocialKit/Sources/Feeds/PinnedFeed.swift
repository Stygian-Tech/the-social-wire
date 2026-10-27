import ATProtoCore
import Foundation

/// A feed the account has pinned, in the order the account pinned it.
public struct PinnedFeed: Hashable, Codable, Sendable, Identifiable {
    /// The feed generator or list record the feed shows.
    public let uri: ATURI
    /// The feed's display name as the server gives it. Account data, so never localized.
    public let name: String
    /// The feed generator's thumbnail, when supplied by the App View.
    public let avatarURL: URL?

    public var id: ATURI { uri }

    public init(uri: ATURI, name: String, avatarURL: URL? = nil) {
        self.uri = uri
        self.name = name
        self.avatarURL = avatarURL
    }
}
