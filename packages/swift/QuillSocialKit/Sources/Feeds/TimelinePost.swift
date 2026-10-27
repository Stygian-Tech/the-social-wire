import Foundation

public struct TimelinePost: Hashable, Sendable, Identifiable {
    public var id: String { uri }

    public let uri: String
    public let cid: String
    public let author: TimelineAuthor
    public let text: String
    public let facets: [TimelineFacet]
    public let createdAt: Date
    public let replyCount: Int
    public let repostCount: Int
    public let likeCount: Int
    public let quoteCount: Int
    public let repostedBy: TimelineAuthor?
    public let images: [TimelineImage]
    public let viewerLikeURI: String?
    public let viewerRepostURI: String?
    public let replyRootURI: String?
    public let replyRootCID: String?
    public let replyParentURI: String?
    public let replyingTo: TimelineAuthor?
    public let quote: TimelineQuote?
    public let labels: [TimelineLabel]
    public let video: TimelineVideo?
    public let externalEmbed: TimelineExternalEmbed?

    public init(
        uri: String,
        cid: String,
        author: TimelineAuthor,
        text: String,
        facets: [TimelineFacet] = [],
        createdAt: Date,
        replyCount: Int = 0,
        repostCount: Int = 0,
        likeCount: Int = 0,
        quoteCount: Int = 0,
        repostedBy: TimelineAuthor? = nil,
        images: [TimelineImage] = [],
        viewerLikeURI: String? = nil,
        viewerRepostURI: String? = nil,
        replyRootURI: String? = nil,
        replyRootCID: String? = nil,
        replyParentURI: String? = nil,
        replyingTo: TimelineAuthor? = nil,
        quote: TimelineQuote? = nil,
        labels: [TimelineLabel] = [],
        video: TimelineVideo? = nil,
        externalEmbed: TimelineExternalEmbed? = nil
    ) {
        self.uri = uri
        self.cid = cid
        self.author = author
        self.text = text
        self.facets = facets
        self.createdAt = createdAt
        self.replyCount = replyCount
        self.repostCount = repostCount
        self.likeCount = likeCount
        self.quoteCount = quoteCount
        self.repostedBy = repostedBy
        self.images = images
        self.viewerLikeURI = viewerLikeURI
        self.viewerRepostURI = viewerRepostURI
        self.replyRootURI = replyRootURI
        self.replyRootCID = replyRootCID
        self.replyParentURI = replyParentURI
        self.replyingTo = replyingTo
        self.quote = quote
        self.labels = labels
        self.video = video
        self.externalEmbed = externalEmbed
    }

    public func replacingExternalEmbed(_ externalEmbed: TimelineExternalEmbed?) -> Self {
        Self(
            uri: uri, cid: cid, author: author, text: text, facets: facets, createdAt: createdAt,
            replyCount: replyCount, repostCount: repostCount, likeCount: likeCount, quoteCount: quoteCount,
            repostedBy: repostedBy, images: images, viewerLikeURI: viewerLikeURI,
            viewerRepostURI: viewerRepostURI, replyRootURI: replyRootURI, replyRootCID: replyRootCID,
            replyParentURI: replyParentURI, replyingTo: replyingTo, quote: quote,
            labels: labels, video: video, externalEmbed: externalEmbed
        )
    }

    public func replacingQuote(_ quote: TimelineQuote?) -> Self {
        Self(
            uri: uri, cid: cid, author: author, text: text, facets: facets, createdAt: createdAt,
            replyCount: replyCount, repostCount: repostCount, likeCount: likeCount, quoteCount: quoteCount,
            repostedBy: repostedBy, images: images, viewerLikeURI: viewerLikeURI,
            viewerRepostURI: viewerRepostURI, replyRootURI: replyRootURI, replyRootCID: replyRootCID,
            replyParentURI: replyParentURI, replyingTo: replyingTo, quote: quote,
            labels: labels, video: video, externalEmbed: externalEmbed
        )
    }
}
