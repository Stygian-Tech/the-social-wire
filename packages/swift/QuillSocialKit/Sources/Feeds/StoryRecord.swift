import Foundation

public struct StoryRecord: Hashable, Sendable, Identifiable {
    public let uri: String
    public let blobCID: String
    public let mimeType: String
    public let createdAt: Date
    public let expiresAt: Date

    public var id: String { uri }

    public init(uri: String, blobCID: String, mimeType: String, createdAt: Date, expiresAt: Date) {
        self.uri = uri
        self.blobCID = blobCID
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
