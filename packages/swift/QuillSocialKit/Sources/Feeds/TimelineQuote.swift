import Foundation

public struct TimelineQuote: Hashable, Sendable, Identifiable {
    public var id: String { uri }

    public let uri: String
    public let cid: String
    public let author: TimelineAuthor
    public let text: String
    public let facets: [TimelineFacet]
    public let createdAt: Date
    public let images: [TimelineImage]
    public let video: TimelineVideo?
    public let externalEmbed: TimelineExternalEmbed?

    public init(
        uri: String,
        cid: String,
        author: TimelineAuthor,
        text: String,
        facets: [TimelineFacet] = [],
        createdAt: Date,
        images: [TimelineImage] = [],
        video: TimelineVideo? = nil,
        externalEmbed: TimelineExternalEmbed? = nil
    ) {
        self.uri = uri
        self.cid = cid
        self.author = author
        self.text = text
        self.facets = facets
        self.createdAt = createdAt
        self.images = images
        self.video = video
        self.externalEmbed = externalEmbed
    }

    public func replacingExternalEmbed(_ externalEmbed: TimelineExternalEmbed?) -> Self {
        Self(
            uri: uri,
            cid: cid,
            author: author,
            text: text,
            facets: facets,
            createdAt: createdAt,
            images: images,
            video: video,
            externalEmbed: externalEmbed
        )
    }
}
