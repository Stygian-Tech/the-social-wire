import Foundation

public struct TimelineVideo: Hashable, Sendable {
    public let playlistURL: URL
    public let thumbnailURL: URL?
    public let altText: String
    public let width: Int?
    public let height: Int?

    public init(playlistURL: URL, thumbnailURL: URL? = nil, altText: String = "", width: Int? = nil, height: Int? = nil) {
        self.playlistURL = playlistURL
        self.thumbnailURL = thumbnailURL
        self.altText = altText
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 16.0 / 9.0 }
        // Tall media stays bounded in scrolling feeds.
        return max(0.75, min(2, Double(width) / Double(height)))
    }
}
