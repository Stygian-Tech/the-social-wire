import Foundation

public struct TangledStringEmbedMetadata: Hashable, Sendable {
    public let contents: String
    public let filename: String
    public let description: String?
    public let authorName: String?
    public let authorAvatarURL: URL?

    public init(
        contents: String,
        filename: String,
        description: String?,
        authorName: String?,
        authorAvatarURL: URL?
    ) {
        self.contents = contents
        self.filename = filename
        self.description = description
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
    }
}
