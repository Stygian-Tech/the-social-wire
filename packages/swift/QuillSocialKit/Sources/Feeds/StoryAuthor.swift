import Foundation

public struct StoryAuthor: Hashable, Sendable, Identifiable {
    public let did: String
    public let handle: String
    public let displayName: String?
    public let avatarURL: URL?

    public var id: String { did }

    public init(did: String, handle: String, displayName: String? = nil, avatarURL: URL? = nil) {
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
