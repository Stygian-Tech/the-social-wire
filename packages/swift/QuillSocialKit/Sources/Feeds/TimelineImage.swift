import Foundation

public struct TimelineImage: Hashable, Sendable, Identifiable {
    public var id: URL { fullsizeURL }

    public let thumbnailURL: URL
    public let fullsizeURL: URL
    public let altText: String
    public let width: Int?
    public let height: Int?
    public let originalGIFDID: String?
    public let originalGIFCID: String?

    public init(
        thumbnailURL: URL,
        fullsizeURL: URL,
        altText: String,
        width: Int? = nil,
        height: Int? = nil,
        originalGIFDID: String? = nil,
        originalGIFCID: String? = nil
    ) {
        self.thumbnailURL = thumbnailURL
        self.fullsizeURL = fullsizeURL
        self.altText = altText
        self.width = width
        self.height = height
        self.originalGIFDID = originalGIFDID
        self.originalGIFCID = originalGIFCID
    }
}
