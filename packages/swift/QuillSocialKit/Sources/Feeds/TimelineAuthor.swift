import Foundation

public struct TimelineAuthor: Hashable, Sendable, Identifiable {
    public var id: String { did }

    public let did: String
    public let handle: String
    public let displayName: String?
    public let avatarURL: URL?
    public let labels: [TimelineLabel]
    public let verifications: [TimelineVerification]
    public let isLiveStreaming: Bool

    public init(
        did: String,
        handle: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        labels: [TimelineLabel] = [],
        verifications: [TimelineVerification] = [],
        isLiveStreaming: Bool = false
    ) {
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.labels = labels
        self.verifications = verifications
        self.isLiveStreaming = isLiveStreaming
    }
}
