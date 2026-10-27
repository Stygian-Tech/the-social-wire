import Foundation

public struct AtmoRsvpAttendee: Hashable, Sendable, Identifiable {
    public let did: String
    public let displayName: String?
    public let avatarURL: URL?
    public let status: AtmoRsvpStatus

    public var id: String { did }

    public init(did: String, displayName: String?, avatarURL: URL?, status: AtmoRsvpStatus) {
        self.did = did
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.status = status
    }
}
